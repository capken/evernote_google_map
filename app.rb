require 'sinatra'
require 'sinatra/json'
require 'uri'

$LOAD_PATH.push(File.expand_path(File.dirname(__FILE__)))
require "evernote_config.rb"

include Evernote::EDAM

use Rack::Session::Cookie, :key => 'rack.session',
                           #:domain => 'localhost',
                           :expire_after => 2592000, # one month
                           :secret => 'change_me'

enable :logging

configure do
  file = File.new("#{settings.root}/log/#{settings.environment}.log", 'a+')
  file.sync = true
  use Rack::CommonLogger, file
end

CACHE_DIR = "/tmp/evernote_map"
Dir.mkdir(CACHE_DIR, 0700) unless File.directory? CACHE_DIR

helpers do

  def request_token
    session[:request_token]
  end

  def authorize_url
    request_token.authorize_url
  end

  def auth_token
    session[:auth_token]
  end

  def filter
    @filter = NoteStore::NoteFilter.new
    @filter.order = Type::NoteSortOrder::UPDATED

    return @filter
  end

  def spec
    @spec = NoteStore::NotesMetadataResultSpec.new
    @spec.includeTitle = true

    return @spec
  end

  def note_url(note, user)
    "https://sandbox.evernote.com/shard/#{user.shardId}/view/notebook/#{note.guid}"
  end

  def latest_notes(max)
    @note_store.findNotesMetadata(
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

  def dump_static_map(lat, lng, zoom, marker)
    params = {
      :center => "#{lat},#{lng}",
      :zoom => zoom,
      :scale => 1,
      :size => "600x450",
      :maptype => "roadmap",
      :sensor => false
    }

    params[:markers] = 
      "color:red|label:|#{marker.lat},#{marker.lng}" if marker
    
    params = params.map { |k,v| "#{k}=#{v}" }.join("&")

    url = [map_provider_endpoint, "?", params].join

    system("curl \"#{url}\" -o #{map_image_path(lat, lng)}")
  end

  def get_marker(params)
    marker = nil
    if params["mlat"] and params["mlng"]
      marker = OpenStruct.new
      marker.lat = params["mlat"] 
      marker.lng = params["mlng"] 
    end

    return marker
  end

  def hash_func
    @hash ||= Digest::MD5.new
  end
  
  def image_resource_of(lat, lng, room, marker)
    if dump_static_map(lat, lng, room, marker)
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

  def image_style
    [
      "padding: 5px;",
      "background-color: white;",
      "box-shadow: 0 1px 3px rgba(34, 25, 25, 0.4);",
      "-moz-box-shadow: 0 1px 2px rgba(34,25,25,0.4);",
      "-webkit-box-shadow: 0 1px 3px rgba(34, 25, 25, 0.4);"
    ].join
  end

  def image_content(resource, link)
    %Q{
    <div>
      <a shape="rect" href="#{link}">
        <en-media type="image/png" style="#{image_style}" hash="#{hash_hex_of(resource)}"></en-media>
      </a>
    </div>
    }
  end

  def new_note_content(body)
    %Q{<?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd">
    <en-note>#{body}</en-note>
    }
  end
  
  def update_note(guid, resource, link)
    begin
      note = @note_store.getNote(guid, true, true, true, true)
      note.resources << resource
      note.content.gsub!(/(?=<\/en-note>)/, image_content(resource, link))
      @note_store.updateNote(note)
      user = @user_store.getUser
      [200, {"note_url" => note_url(note, user)}]
    rescue Error::EDAMNotFoundException
      logger.info "EDAMNotFoundException: Invalid notebook GUID #{guid}"
      [404, {"error" => "Note not found: #{guid}"}]
    end
  end
  
  def create_note(note_name, resource, link)
    new_note = Type::Note.new
    new_note.title = note_name
    new_note.resources = [ resource ]
    new_note.content = new_note_content(image_content(resource, link))
    warn new_note.content
  
    begin
      note = @note_store.createNote(new_note)
      user = @user_store.getUser
      [200, {"note_url" => note_url(note, user)}]
    rescue Error::EDAMUserException => edue
      ## http://dev.evernote.com/documentation/reference/Errors.html#Enum_EDAMErrorCode
      [500, {"error" => "EDAMUserException: #{edue.errorCode}"}]
    end
  end

  def map_link(lat, lng, zoom)
    "https://maps.google.com/maps?q=loc:#{lat},#{lng}&amp;z=#{zoom}"
  end
end

before '/api/*' do
  if auth_token.nil?
    logger.info "auth_token is nil"
    halt 401,  "auth token is invalid"
  else
    @client = EvernoteOAuth::Client.new(
      token: auth_token,
      sandbox: SANDBOX
    )
    begin
      @user_store = @client.user_store
      @note_store = @client.note_store
    rescue Error::EDAMUserException => e
      logger.error "auth token is invalid"
      halt(401, "auth token is invalid") if e.errorCode == Error::EDAMErrorCode::AUTH_EXPIRED
    end
  end
end

get '/' do
  redirect '/index.html'
end

get '/api/notes' do
  notes = []
  latest_notes(5).each do |note|
    notes << { "guid" => note.guid, "title" => note.title }
  end

  json :notes => notes 
end

# create a new note
post '/api/notes' do
  lat, lng, zoom = params["lat"], params["lng"], params["zoom"]
  marker = get_marker params
  note_name = URI.decode(params['note_name'])

  logger.info "location='#{lat},#{lng},#{zoom}'"
  resource = image_resource_of(lat, lng, zoom, marker)
  link = map_link(marker.lat, marker.lng, zoom)

  code, message = create_note(note_name, resource, link)

  status code
  json message
end

# update a note
put '/api/notes/:id' do
  lat, lng, zoom = params["lat"], params["lng"], params["zoom"]
  marker = get_marker params
  guid = params['id']

  logger.info "location='#{lat},#{lng},#{zoom}'"
  resource = image_resource_of(lat, lng, zoom, marker)
  link = map_link(marker.lat, marker.lng, zoom)

  code, message = update_note(guid, resource, link)

  status code
  json message
end

# oauth related routers

get '/oauth/request_token' do
  @client ||= EvernoteOAuth::Client.new(
    consumer_key:OAUTH_CONSUMER_KEY,
    consumer_secret:OAUTH_CONSUMER_SECRET,
    sandbox: SANDBOX
  )

  callback_url = request.url.gsub("request_token", "callback")
  logger.info "callback_url=" + callback_url
  begin
    session[:request_token] = @client.request_token(
      :oauth_callback => callback_url)
    redirect '/oauth/authorize'
  rescue => e
    @last_error = "Error obtaining temporary credentials: #{e.message}"
    erb :error
  end
end

get '/oauth/authorize' do
  if request_token
    redirect authorize_url
  else
    @last_error = "Request token not set."
    erb :error
  end
end

get '/oauth/callback' do
  unless params[:oauth_verifier] || request_token
    @last_error = "Content owner did not authorize the temporary credentials"
    halt erb :error
  end

  begin
    access_token = request_token.get_access_token(
      :oauth_verifier => params[:oauth_verifier]
    )
    session.clear
    session[:auth_token] = access_token.token
    redirect (params[:back_url] || '/')
  rescue => e
    @last_error = 'Error extracting access token'
    erb :error
  end
end

get '/oauth/reset' do
  session.clear
  redirect '/'
end
