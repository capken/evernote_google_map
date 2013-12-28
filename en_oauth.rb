
require 'sinatra'
require 'sinatra/json'
require 'uri'

$LOAD_PATH.push(File.expand_path(File.dirname(__FILE__)))
require "evernote_config.rb"

include Evernote::EDAM

enable :sessions
set :session_secret, 'super secret'

CACHE_DIR = "/tmp/evernote_map"
Dir.mkdir(CACHE_DIR, 0700) unless File.directory? CACHE_DIR

helpers do

  def request_token
    session[:request_token]
  end

  def authorize_url
    request_token.authorize_url
  end

  def access_token
    session[:access_token]
  end

  def auth_token
    access_token ? access_token.token : nil
  end

  def client
    @client ||= EvernoteOAuth::Client.new(
      token: auth_token,
      consumer_key:OAUTH_CONSUMER_KEY,
      consumer_secret:OAUTH_CONSUMER_SECRET,
      sandbox: SANDBOX
    )
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

  def filter
    if @filter.nil?
      @filter = NoteStore::NoteFilter.new
      @filter.order = Type::NoteSortOrder::UPDATED
    end

    return @filter
  end

  def spec
    if @spec.nil?
      @spec = NoteStore::NotesMetadataResultSpec.new
      @spec.includeTitle = true
    end

    return @spec
  end

  def latest_notes(max)
    note_store.findNotesMetadata(
      auth_token, filter, 0, max, spec
    ).notes
  end

  def map_provider_endpoint
    "http://maps.googleapis.com/maps/api/staticmap"
  end

  def map_image_name(lat, lng)
    "#{lat}_#{lng}.png"
  end

  def map_image_path(lat, lng)
    "#{CACHE_DIR}/#{map_image_name(lat, lng)}"
  end

  def dump_static_map(lat, lng, zoom)
    params = {
      :center => "#{lat},#{lng}",
      :zoom => zoom,
      :scale => 1,
      :size => "600x450",
      :maptype => "roadmap",
      :sensor => false
    }.map { |k,v| "#{k}=#{v}" }.join("&")

    url = [map_provider_endpoint, "?", params].join

    system("curl \"#{url}\" -o #{map_image_path(lat, lng)}")
  end

  def hash_func
    @hash ||= Digest::MD5.new
  end
  
  def image_resource_of(location)
    lat, lng = location.split ','

    if dump_static_map(lat, lng, 14)
      image_data = File.open(
        map_image_path(lat, lng), "rb"
      ) { |io| io.read }
  
      data = Type::Data.new
      data.size = image_data.size
      data.body = image_data
      data.bodyHash = hash_func.digest(image_data)
  
      resource = Type::Resource.new
      resource.mime = "image/png"
      resource.data = data
      resource.attributes = Type::ResourceAttributes.new
      resource.attributes.fileName = map_image_name(lat, lng)
  
      return resource
    end
  end

  def hash_hex_of(resource)
    hash_func.hexdigest(resource.data.body)
  end
  
  def update_note(guid, resource)
    begin
      note = note_store.getNote(guid, true, true, true, true)
      note.resources << resource
      note.content.gsub!(/<\/en-note>/,
        "<en-media type=\"image/png\" hash=\"#{hash_hex_of(resource)}\" /></en-note>")
      warn note.content
      note_store.updateNote(note)
      [200, {"guid" => note.guid}]
    rescue Error::EDAMNotFoundException
      warn "EDAMNotFoundException: Invalid notebook GUID #{guid}"
      [404, {"error" => "Note not found: #{guid}"}]
    end
  end
  
  def create_note(note_name, resource)
    n_body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    n_body += "<!DOCTYPE en-note SYSTEM \"http://xml.evernote.com/pub/enml2.dtd\">"
    n_body += "<en-note><en-media type=\"image/png\" hash=\"#{hash_hex_of(resource)}\" /></en-note>"
  
    new_note = Type::Note.new
    new_note.title = note_name
    new_note.resources = [ resource ]
    new_note.content = n_body
  
    begin
      note = note_store.createNote(new_note)
      [200, {"guid" => note.guid}]
    rescue Error::EDAMUserException => edue
      ## http://dev.evernote.com/documentation/reference/Errors.html#Enum_EDAMErrorCode
      warn "EDAMUserException: #{edue}"
      [500, {"error" => "EDAMUserException: #{edue}"}]
    end
  end
end

before '/' do
  redirect "/requesttoken" if access_token.nil?
end

get '/' do
  erb :index
end

get '/map' do
  erb :map
end

get '/latest_five_notes' do
  notes = []
  latest_notes(5).each do |note|
    notes << { "guid" => note.guid, "title" => note.title }
  end

  json :notes => notes 
end

get '/update' do
  guid = params['guid']

  location  = params['location']
  resource = image_resource_of(location)

  code, message = update_note(guid, resource)

  status code
  json message
end

get '/save' do
  note_name = URI.decode(params['note_name'])

  location  = params['location']
  resource = image_resource_of(location)

  code, message = create_note(note_name, resource)

  status code
  json message
end

# oauth related routers

get '/requesttoken' do
  callback_url = request.url.
    chomp("requesttoken").concat("callback")
  begin
    session[:request_token] = client.request_token(
      :oauth_callback => callback_url)
    redirect '/authorize'
  rescue => e
    @last_error = "Error obtaining temporary credentials: #{e.message}"
    erb :error
  end
end

get '/authorize' do
  if request_token
    redirect authorize_url
  else
    @last_error = "Request token not set."
    erb :error
  end
end

get '/callback' do

  unless params[:oauth_verifier] || request_token
    @last_error = "Content owner did not authorize the temporary credentials"
    halt erb :error
  end

  begin
    session[:access_token] = request_token.get_access_token(
      :oauth_verifier => params[:oauth_verifier]
    )
    redirect '/'
  rescue => e
    @last_error = 'Error extracting access token'
    erb :error
  end
end

get '/reset' do
  session.clear
  redirect '/'
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
