class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  #protect_from_forgery with: :exception

  before_action :log_session

  def index
    session.clear
  end

  def basic_info
    session.clear
  end

  def basic_info_submit
    session[:name] = params[:name]
    session[:home_address] = params[:home_address]
    session[:home_zip_code] = params[:home_zip_code]
    session[:home_city] = params[:home_city]
    session[:home_state] = params[:home_state]
    redirect_to '/application/contact_info'
  end

  def contact_info
    @language_options = %w(English Spanish Mandarin Cantonese Vietnamese Russian Tagalog Other)
  end

  def contact_info_submit
    session[:home_phone_number] = params[:home_phone_number]
    session[:email] = params[:email]
    session[:primary_language] = params[:primary_language]
    redirect_to '/application/sex_and_ssn'
  end

  def sex_and_ssn
  end

  def sex_and_ssn_submit
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
    parsed_date = Chronic.parse(params[:date_of_birth])
    if parsed_date != nil
      session[:date_of_birth] = parsed_date.strftime('%m/%d/%y')
    else
      session[:date_of_birth] = ''
    end
    session[:ssn] = params[:ssn]
    session[:sex] = sex
    redirect_to '/application/household_question'
  end

  def household_question
  end

  def additional_household_member
  end

  def additional_household_member_submit
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
    parsed_date = Chronic.parse(params[:their_date_of_birth])
    if parsed_date != nil
      clean_date_of_birth = parsed_date.strftime('%m/%d/%y')
    else
      clean_date_of_birth = ''
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
    redirect_to '/application/additional_household_question'
  end

  def additional_household_question
  end

  def documents
    @document_set_key = SecureRandom.hex
    session[:document_set_key] = @document_set_key
  end

  def interview
  end

  def interview_submit
    selected_times = params.select do |key, value|
      value == "on"
    end.keys
    underscored_selections = selected_times.map do  |t|
      t.gsub("-","_")
    end
    underscored_selections.each do |selection|
      session["interview_#{selection}"] = 'Yes'
    end
    redirect_to '/application/info_sharing'
  end

  def info_sharing
  end

  def info_sharing_submit
    [:contact_by_phone_call, :contact_by_text_message, :contact_by_email].each do |preference_name|
      if params[preference_name] == 'on'
        session[preference_name] = true
      else
        session[preference_name] = false
      end
    end
    redirect_to '/application/rights_and_regs'
  end

  def rights_and_regs
  end

  def rights_and_regs_submit
    redirect_to '/application/review_and_submit'
  end

  def review_and_submit
  end

  def review_and_submit_submit
    writer = Calfresh::ApplicationWriter.new
    input_for_writer = session.to_hash.symbolize_keys
    input_for_writer[:signature] = params[:signature]
    input_for_writer[:signature_agree] = params[:signature_agree]
    input_for_writer[:name_page3] = session[:name]
    input_for_writer[:ssn_page3] = session[:ssn]
    input_for_writer[:language_preference_reading] = session[:primary_language]
    input_for_writer[:language_preference_writing] = session[:primary_language]
    @application = writer.fill_out_form(input_for_writer)
      doc_key = session[:document_set_key]
      uploaded_documents = Upload.where(document_set_key: doc_key)
      if uploaded_documents.count > 0
        # Do processing to combine application
        temp_files = Array.new
        uploaded_documents.each do |doc|
          temp_files << doc.to_local_temp_file
        end
        single_pdf_doc_for_verifications = DocumentProcessor.combine_documents_into_single_pdf(temp_files)
        path_for_pdf_to_save = "/tmp/app_with_docs_#{doc_key}.pdf"
        system("pdftk #{@application.final_pdf_path} #{single_pdf_doc_for_verifications.path} cat output #{path_for_pdf_to_save}")
      else
        path_for_pdf_to_save = @application.final_pdf_path
      end

      case_data = session.to_hash
      case_data["signature"] = params[:signature]
      case_data["signature_agree"] = params[:signature_agree]
      case_data["public_id"] = session["document_set_key"]
      data_to_save = Case.process_data_for_storage(case_data)
      c = Case.new(data_to_save)
      File.open(path_for_pdf_to_save) do |f|
        c.pdf = f
      end
      c.save
      pdf_url = case_download_url(c.public_id)
      puts pdf_url
      client = SendGrid::Client.new(api_user: ENV['SENDGRID_USERNAME'], api_key: ENV['SENDGRID_PASSWORD'])
      mail = SendGrid::Mail.new(
        to: ENV['EMAIL_ADDRESS_TO_SEND_TO'],
        from: 'suzanne@cleanassist.org',
        subject: 'New Clean CalFresh Application!',
        text: <<EOF
Hi there!

An application for CalFresh benefits was just submitted!

The below link contains a PDF file with:

- A completed CF-285
- An information release authorization
- Verification documents

Application PDF: #{pdf_url}

The link requires a username and password to protect client privacy - if you don't have a password to access it, please get in touch with Jake Solomon at jacob@codeforamerica.org

When you finish clearing the case, please help us track the case by filling out a bit of info here: http://c4a.me/cleancases

Thanks for your time!

Suzanne, your friendly neighborhood CalFresh robot
EOF
      )
      @email_result_application = client.send(mail)
      puts @email_result_application
    redirect_to '/application/confirmation'
  end

  def document_instructions
    # updated route so that succesful applications now see /confirmation instead of /document_instructions
  end

  def confirmation
    render :layout => "confirmation"
  end

  private
  def log_session
    session_data = session.to_hash.select do |k,v|
      ['_csrf_token', 'session_id'].include?(k) == false
    end
    puts session_data
  end
end
