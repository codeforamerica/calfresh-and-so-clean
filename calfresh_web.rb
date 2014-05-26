require 'sinatra'
require 'rack/ssl'
require './calfresh'
require './faxer'

class CalfreshWeb < Sinatra::Base
  use Rack::SSL unless settings.environment == :development

  get '/' do
    erb :index
  end

  post '/applications' do
    writer = Calfresh::ApplicationWriter.new
    input_for_writer = params
    input_for_writer[:name_page3] = params[:name]
    input_for_writer[:ssn_page3] = params[:ssn]
    @application = writer.fill_out_form(input_for_writer)
    if @application.has_pngs?
      @fax_result = Faxer.send_fax(ENV['FAX_DESTINATION_NUMBER'], @application.png_file_set)
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
