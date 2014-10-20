require 'sinatra'
require 'rack/ssl'
require 'encrypted_cookie'
require 'sendgrid-ruby'
require 'redis'
require 'securerandom'
require 'zipruby'
require './calfresh'
require './faxer'

class CalfreshWeb < Sinatra::Base
  if settings.environment == :production
    use Rack::Session::EncryptedCookie, :secret => ENV['SECRET_TOKEN']
    use Rack::SSL unless settings.environment
  elsif settings.environment == :development
    # Breaking tests, but needed for dev use
    #enable :sessions
  end

  configure do
    set :redis_url, URI.parse(ENV["REDISTOGO_URL"])
  end

  before do
    puts session
  end

  get '/' do
    redirect to('/application/basic_info'), 303
    #@language_options = %w(English Spanish Mandarin Cantonese Vietnamese Russian Tagalog Other)
    #erb :index
  end

  get '/application/basic_info' do
    session.clear
    erb :basic_info, layout: :v4_layout
  end

  post '/application/basic_info' do
    session[:name] = params[:name]
    session[:date_of_birth] = params[:date_of_birth]
    redirect to('/application/contact_info'), 303
  end

  get '/application/contact_info' do
    @language_options = %w(English Spanish Mandarin Cantonese Vietnamese Russian Tagalog Other)
    erb :contact_info, layout: :v4_layout
  end

  post '/application/contact_info' do
    session[:home_phone_number] = params[:home_phone_number]
    session[:email] = params[:email]
    session[:home_address] = params[:home_address]
    session[:home_zip_code] = params[:home_zip_code]
    session[:home_city] = params[:home_city]
    session[:home_state] = params[:home_state]
    session[:primary_language] = params[:primary_language]
    redirect to('/application/sex_and_ssn'), 303
  end

  get '/application/sex_and_ssn' do
    erb :sex_and_ssn, layout: :v4_layout
  end

  post '/application/sex_and_ssn' do
    sex_field_name = params.select do |key, value|
      value == "on"
    end.keys.first
    sex = case sex_field_name
      when "Male"
        "M"
      when "Female"
        "F"
      else
        ""
    end
    session[:ssn] = params[:ssn]
    session[:sex] = sex
    redirect to('/application/medical'), 303
  end

  get '/application/medical' do
    erb :medical, layout: :v4_layout
  end

  post '/application/medical' do
    if params[:yes] == "on"
      session[:medi_cal_interest] = "on"
    end
    redirect to('/application/interview'), 303
  end

  get '/application/interview' do
    erb :interview, layout: :v4_layout
  end

  post '/application/interview' do
    selected_times = params.select do |key, value|
      value == "on"
    end.keys
    underscored_selections = selected_times.map do  |t|
      t.gsub("-","_")
    end
    underscored_selections.each do |selection|
      session["interview_#{selection}"] = 'Yes'
    end
    redirect to('/application/household_question'), 303
  end

  get '/application/household_question' do
    erb :household_question, layout: :v4_layout
  end

  get '/application/additional_household_member' do
    erb :additional_household_member, layout: :v4_layout
  end

  post '/application/additional_household_member' do
    sex_field_name = params.select do |key, value|
      value == "on"
    end.keys.first
    sex = case sex_field_name
      when "Male"
        "M"
      when "Female"
        "F"
      else
        ""
    end
    clean_date_of_birth = ""
    if params["their_date_of_birth"] != ""
      date_of_birth_array = params["their_date_of_birth"].split('/')
      birth_year = date_of_birth_array[2]
      if birth_year.length == 4
        clean_date_of_birth = date_of_birth_array[0..1].join('/') + "/#{birth_year[-2..-1]}"
      else
        clean_date_of_birth = params["their_date_of_birth"]
      end
    end
    session[:additional_household_members] ||= []
    name = if params["their_name"] == nil
             ""
           else
             params["their_name"]
           end
    ssn = if params["their_ssn"] == nil
             ""
           else
             params["their_ssn"]
           end
    hash_for_person = {
      name: name,
      date_of_birth: clean_date_of_birth,
      ssn: ssn,
      sex: sex
    }
    session[:additional_household_members] << hash_for_person
    redirect to('/application/household_question'), 303
  end

  get '/application/review_and_submit' do
    erb :review_and_submit, layout: :v4_layout
  end

  post '/application/review_and_submit' do
    puts params
    writer = Calfresh::ApplicationWriter.new
    input_for_writer = session
    input_for_writer[:signature] = params["signature"]
    if session[:date_of_birth] != ""
      date_of_birth_array = session[:date_of_birth].split('/')
      birth_year = date_of_birth_array[2]
      if birth_year.length == 4
        input_for_writer[:date_of_birth] = date_of_birth_array[0..1].join('/') + "/#{birth_year[-2..-1]}"
      end
    end
    input_for_writer[:name_page3] = session[:name]
    input_for_writer[:ssn_page3] = session[:ssn]
    input_for_writer[:language_preference_reading] = session[:primary_language]
    input_for_writer[:language_preference_writing] = session[:primary_language]
    @application = writer.fill_out_form(input_for_writer)
    #if @application.has_pngs?
      client = SendGrid::Client.new(api_user: ENV['SENDGRID_USERNAME'], api_key: ENV['SENDGRID_PASSWORD'])
      mail = SendGrid::Mail.new(
        to: ENV['EMAIL_ADDRESS_TO_SEND_TO'],
        from: 'suzanne@cleanassist.org',
        subject: 'New Clean CalFresh Application!',
        text: <<EOF
Hi there!

An application for Calfresh benefits was just submitted!

You can find a completed CF-285 in the attached .zip file. You will probably receive another e-mail shortly containing photos of their verification documents.

The .zip file attached is encrypted because it contains sensitive personal information. If you don't have a password to access it, please get in touch with Jake Solomon at jacob@codeforamerica.org

When you finish clearing the case, please help us track the case by filling out a bit of info here: http://bit.ly/cleancases

Thanks for your time!

Suzanne, your friendly neighborhood CalFresh robot
EOF
      )
      random_value = SecureRandom.hex
      zip_file_path = "/tmp/#{random_value}.zip"
      Zip::Archive.open(zip_file_path, Zip::CREATE) do |ar|
        ar.add_file(@application.final_pdf_path) # add file to zip archive
      end
      Zip::Archive.encrypt(zip_file_path, ENV['ZIP_FILE_PASSWORD'])
      puts zip_file_path
      mail.add_attachment(zip_file_path)
      @email_result_application = client.send(mail)
      puts @email_result_application
      #erb :after_fax
    #end
=begin
    else
      puts "No PNGs! WTF!?!"
      #redirect to('/')
    end
=end
    redirect to('/application/confirmation'), 303
  end

  get '/application/confirmation' do
    @user_token = SecureRandom.hex
    erb :confirmation, layout: :v4_layout
  end

  get '/document_question' do
    @user_token = SecureRandom.hex
    erb :document_question, layout: :verification_doc_layout
  end

  get '/documents/:user_token/:number_of_docs' do
    @token = params[:user_token]
    @number_of_docs = params[:number_of_docs]
    erb :new_doc, layout: :verification_doc_layout
  end

  post '/documents/:user_token/:doc_number/create' do
    token = params[:user_token]
    doc_number = params[:doc_number].to_i
    redis = Redis.new(:url => settings.redis_url)
    doc = Calfresh::VerificationDoc.new(params)
    image_binary = IO.binread(doc.original_file_path)
    key_base = "#{token}_#{doc_number}"
    filename = params["identification"][:filename].gsub(" ","")
    redis.set(key_base + "_binary", image_binary)
    redis.expire(key_base + "_binary", 1800)
    redis.set(key_base + "_filename", filename)
    redis.expire(key_base + "_filename", 1800)
    new_number_of_docs = doc_number + 1
    redirect to("/documents/#{params[:user_token]}/#{new_number_of_docs}"), 302
  end

  post '/documents/:user_token/:doc_number/submit' do
    token = params[:user_token]
    max_doc_index = params[:doc_number].to_i - 1
    redis = Redis.new(:url => settings.redis_url)
    file_paths_array = Array.new
    (0..max_doc_index).to_a.each do |index|
      # Get binary from Redis
      binary = redis.get("#{token}_#{index}_binary")
      # Get filename from Redis
      filename = redis.get("#{token}_#{index}_filename")
      # Write file to /tmp with proper extension
      temp_file_path = "/tmp/" + token + filename
      File.open(temp_file_path, 'wb') do |file|
        file.write(binary)
      end
      # Add full path for new file to array
      file_paths_array << temp_file_path
      # Delete Redis data
      redis.del("#{token}_#{index}_binary")
      redis.del("#{token}_#{index}_filename")
    end
    # Combine all files into single PDF
    final_pdf_path = "/tmp/#{token}_all_images.pdf"
    system("convert #{file_paths_array.join(' ')} #{final_pdf_path}")
    # Encrypt and zip file
    zip_file_path = "/tmp/#{token}_zipped.zip"
    Zip::Archive.open(zip_file_path, Zip::CREATE) do |ar|
      ar.add_file(final_pdf_path) # add file to zip archive
    end
    Zip::Archive.encrypt(zip_file_path, ENV['ZIP_FILE_PASSWORD'])
    puts zip_file_path
    # Email file
    sendgrid_client = SendGrid::Client.new(api_user: ENV['SENDGRID_USERNAME'], api_key: ENV['SENDGRID_PASSWORD'])
    mail = SendGrid::Mail.new(
      to: ENV['EMAIL_ADDRESS_TO_SEND_TO'],
      from: 'suzanne@cleanassist.org',
      subject: 'New Clean CalFresh Verification Docs!',
      text: <<EOF
Hi there!

Verification docs were just submitted for a CalFresh application!

You can find the docs in the attached .zip file.

The .zip file attached is encrypted because it contains sensitive personal information. If you don't have a key to access it, please get in touch with Jake Soloman at jacob@codeforamerica.org

Thanks for your time!

Suzanne, your friendly neighborhood CalFresh robot
EOF
    )
    mail.add_attachment(zip_file_path)
    @email_result_application = sendgrid_client.send(mail)
    puts @email_result_application
    # ...
    redirect to("/complete"), 302
  end

  get '/first_id_doc' do
    erb :first_id_doc, layout: :v4_layout
  end

  post '/first_id_doc' do
    puts params
    doc = Calfresh::VerificationDoc.new(params)
    doc.pre_process!
    fax_result_verification_doc = Faxer.send_fax(ENV['FAX_DESTINATION_NUMBER'], doc.processed_file_set)
    puts fax_result_verification_doc.message
    redirect to('/next_id_doc'), 303
  end

  get '/next_id_doc' do
    erb :next_id_doc, layout: :verification_doc_layout
  end

  post '/next_id_doc' do
    puts params
    doc = Calfresh::VerificationDoc.new(params)
    doc.pre_process!
    fax_result_verification_doc = Faxer.send_fax(ENV['FAX_DESTINATION_NUMBER'], doc.processed_file_set)
    puts fax_result_verification_doc.message
    redirect to('/next_id_doc'), 303
  end

  get '/first_income_doc' do
    erb :first_income_doc, layout: :verification_doc_layout
  end

  post '/first_income_doc' do
    puts params
    doc = Calfresh::VerificationDoc.new(params)
    doc.pre_process!
    fax_result_verification_doc = Faxer.send_fax(ENV['FAX_DESTINATION_NUMBER'], doc.processed_file_set)
    puts fax_result_verification_doc.message
    redirect to('/next_income_doc'), 303
  end

  get '/next_income_doc' do
    erb :next_income_doc, layout: :verification_doc_layout
  end

  post '/next_income_doc' do
    puts params
    doc = Calfresh::VerificationDoc.new(params)
    doc.pre_process!
    fax_result_verification_doc = Faxer.send_fax(ENV['FAX_DESTINATION_NUMBER'], doc.processed_file_set)
    puts fax_result_verification_doc.message
    redirect to('/next_income_doc'), 303
  end

  get '/first_expense_doc' do
    erb :first_expense_doc, layout: :verification_doc_layout
  end

  post '/first_expense_doc' do
    puts params
    doc = Calfresh::VerificationDoc.new(params)
    doc.pre_process!
    fax_result_verification_doc = Faxer.send_fax(ENV['FAX_DESTINATION_NUMBER'], doc.processed_file_set)
    puts fax_result_verification_doc.message
    redirect to('/next_expense_doc')
  end

  get '/next_expense_doc' do
    erb :next_expense_doc, layout: :verification_doc_layout
  end

  post '/next_expense_doc' do
    puts params
    doc = Calfresh::VerificationDoc.new(params)
    doc.pre_process!
    fax_result_verification_doc = Faxer.send_fax(ENV['FAX_DESTINATION_NUMBER'], doc.processed_file_set)
    puts fax_result_verification_doc.message
    redirect to('/next_expense_doc')
  end

  get '/first_other_doc' do
    erb :first_other_doc, layout: :verification_doc_layout
  end

  post '/first_other_doc' do
    puts params
    doc = Calfresh::VerificationDoc.new(params)
    doc.pre_process!
    fax_result_verification_doc = Faxer.send_fax(ENV['FAX_DESTINATION_NUMBER'], doc.processed_file_set)
    puts fax_result_verification_doc.message
    redirect to('/next_other_doc')
  end

  get '/next_other_doc' do
    erb :next_other_doc, layout: :verification_doc_layout
  end

  post '/next_other_doc' do
    puts params
    doc = Calfresh::VerificationDoc.new(params)
    doc.pre_process!
    fax_result_verification_doc = Faxer.send_fax(ENV['FAX_DESTINATION_NUMBER'], doc.processed_file_set)
    puts fax_result_verification_doc.message
    redirect to('/next_other_doc')
  end

  get '/complete' do
    erb :complete, layout: :verification_doc_layout
  end

  post '/applications' do
    writer = Calfresh::ApplicationWriter.new
    input_for_writer = params
    input_for_writer["sex"] = case params["sex"]
      when "Male"
        "M"
      when "Female"
        "F"
      else
        ""
    end
    if params["date_of_birth"] != ""
      date_of_birth_array = params["date_of_birth"].split('/')
      birth_year = date_of_birth_array[2]
      if birth_year.length == 4
        input_for_writer["date_of_birth"] = date_of_birth_array[0..1].join('/') + "/#{birth_year[-2..-1]}"
      end
    end
    input_for_writer[:name_page3] = params[:name]
    input_for_writer[:ssn_page3] = params[:ssn]
    input_for_writer[:language_preference_reading] = params[:primary_language]
    input_for_writer[:language_preference_writing] = params[:primary_language]
    @application = writer.fill_out_form(input_for_writer)
    if @application.has_pngs?
      @verification_docs = Calfresh::VerificationDocSet.new(params)
      @fax_result_application = Faxer.send_fax(ENV['FAX_DESTINATION_NUMBER'], @application.png_file_set)
      @fax_result_verification_docs = Faxer.send_fax(ENV['FAX_DESTINATION_NUMBER'], @verification_docs.file_array)
      puts @fax_result_application
      puts @fax_result_verification_docs
      erb :after_fax
    else
      puts "No PNGs! WTF!?!"
      redirect to('/')
    end
  end

  get '/applications/:id' do
    send_file Calfresh::Application.new(params[:id]).signed_png_path
  end
end
