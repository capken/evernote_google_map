##
# Copyright 2012 Evernote Corporation. All rights reserved.
##

require 'sinatra'
require 'sinatra/json'
enable :sessions

# Load our dependencies and configuration settings
$LOAD_PATH.push(File.expand_path(File.dirname(__FILE__)))
require "evernote_config.rb"

##
# Verify that you have obtained an Evernote API key
##
before do
  if OAUTH_CONSUMER_KEY.empty? || OAUTH_CONSUMER_SECRET.empty?
    halt '<span style="color:red">Before using this sample code you must edit evernote_config.rb and replace OAUTH_CONSUMER_KEY and OAUTH_CONSUMER_SECRET with the values that you received from Evernote. If you do not have an API key, you can request one from <a href="http://dev.evernote.com/documentation/cloud/">dev.evernote.com/documentation/cloud/</a>.</span>'
  end
end

helpers do
  def auth_token
    session[:access_token].token if session[:access_token]
  end

  def client
    @client ||= EvernoteOAuth::Client.new(token: auth_token, consumer_key:OAUTH_CONSUMER_KEY, consumer_secret:OAUTH_CONSUMER_SECRET, sandbox: SANDBOX)
  end

  def user_store
    @user_store ||= client.user_store
  end

  def note_store
    @note_store ||= client.note_store
  end

  def en_user
    user_store.getUser(auth_token)
  end

  def notebooks
    @notebooks ||= note_store.listNotebooks(auth_token)
  end

  def total_note_count
    filter = Evernote::EDAM::NoteStore::NoteFilter.new
    counts = note_store.findNoteCounts(auth_token, filter, false)
    notebooks.inject(0) do |total_count, notebook|
      total_count + (counts.notebookCounts[notebook.guid] || 0)
    end
  end
end

##
# Index page
##
get '/' do
  erb :index
end

##
# Reset the session
##
get '/reset' do
  session.clear
  redirect '/'
end

##
# Obtain temporary credentials
##
get '/requesttoken' do
  callback_url = request.url.chomp("requesttoken").concat("callback")
  begin
    session[:request_token] = client.request_token(:oauth_callback => callback_url)
    redirect '/authorize'
  rescue => e
    @last_error = "Error obtaining temporary credentials: #{e.message}"
    erb :error
  end
end

##
# Redirect the user to Evernote for authoriation
##
get '/authorize' do
  if session[:request_token]
    redirect session[:request_token].authorize_url
  else
    # You shouldn't be invoking this if you don't have a request token
    @last_error = "Request token not set."
    erb :error
  end
end

##
# Receive callback from the Evernote authorization page
##
get '/callback' do
  unless params['oauth_verifier'] || session['request_token']
    @last_error = "Content owner did not authorize the temporary credentials"
    halt erb :error
  end
  session[:oauth_verifier] = params['oauth_verifier']
  begin
    session[:access_token] = session[:request_token].get_access_token(:oauth_verifier => session[:oauth_verifier])
    redirect '/map'
  rescue => e
    @last_error = 'Error extracting access token'
    erb :error
  end
end

get '/map' do

  image_path = File.join File.dirname(__FILE__), "sample_google_map.png"
  image = File.open(image_path, "rb") {|io| io.read }
  hash_func = Digest::MD5.new

  data = Evernote::EDAM::Type::Data.new
  data.size = image.size
  data.bodyHash = hash_func.digest(image)
  data.body = image

  resource = Evernote::EDAM::Type::Resource.new
  resource.mime = "image/png"
  resource.data = data
  resource.attributes = Evernote::EDAM::Type::ResourceAttributes.new
  resource.attributes.fileName = "sample_google_map.png"

  hash_hex = hash_func.hexdigest(image)

  new_note = Evernote::EDAM::Type::Note.new
  new_note.title = "New note with Google Map"
  new_note.resources = [ resource ]

  n_body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
  n_body += "<!DOCTYPE en-note SYSTEM \"http://xml.evernote.com/pub/enml2.dtd\">"
  n_body += "<en-note><en-media type=\"image/png\" hash=\"#{hash_hex}\" /></en-note>"

  new_note.content = n_body

  begin
    note = note_store.createNote(new_note)
  rescue Evernote::EDAM::Error::EDAMUserException => edue
    ## Something was wrong with the note data
    ## See EDAMErrorCode enumeration for error code explanation
    ## http://dev.evernote.com/documentation/reference/Errors.html#Enum_EDAMErrorCode
    puts "EDAMUserException: #{edue}"
  rescue Evernote::EDAM::Error::EDAMNotFoundException => ednfe
    ## Parent Notebook GUID doesn't correspond to an actual notebook
    puts "EDAMNotFoundException: Invalid parent notebook GUID"
  end

  json :status => 'OK'
end


##
# Access the user's Evernote account and display account data
##
get '/list' do
  begin
    # Get notebooks
    session[:notebooks] = notebooks.map(&:name)
    # Get username
    session[:username] = en_user.username
    # Get total note count
    session[:total_notes] = total_note_count
    erb :index
  rescue => e
    @last_error = "Error listing notebooks: #{e.message}"
    erb :error
  end
end


__END__

@@ error 
<html>
<head>
  <title>Evernote Ruby Example App &mdash; Error</title>
</head>
<body>
  <p>An error occurred: <%= @last_error %></p>
  <p>Please <a href="/reset">start over</a>.</p>
</body>
</html>
