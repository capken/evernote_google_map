require 'sinatra'
require 'sinatra/json'
require 'curb'
require 'uri'

$LOAD_PATH.push(File.expand_path(File.dirname(__FILE__)))
require "evernote_config.rb"

include Evernote::EDAM

use Rack::Session::Cookie, :key => 'rack.session',
                           :expire_after => 15552000, # half of a year
                           :secret => 'change_me'

CACHE_DIR = "/tmp/evernote_map"
Dir.mkdir(CACHE_DIR, 0700) unless File.directory? CACHE_DIR

class RetryException < StandardError; end

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

  def note_url(note)
    host = SANDBOX ? 'sandbox' : 'www'
    # https://www.evernote.com/view/notebook/30396291-fa9e-4e06-b64b-2bab0724dc99
    "https://#{host}.evernote.com/view/notebook/#{note.guid}"
  end

  def latest_notes(max)
    @note_store.findNotesMetadata(
      filter, 0, max, spec
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

  def dump_static_map(lat, lng, zoom, map_type, marker)
    params = {
      :center => "#{lat},#{lng}",
      :zoom => zoom,
      :scale => 1,
      :size => "600x450",
      :maptype => map_type || "roadmap",
      :sensor => false
    }

    params[:markers] = 
      "color:red|label:|#{marker.lat},#{marker.lng}" if marker
    
    params = params.map { |k,v| "#{k}=#{v}" }.join("&")

    url = [map_provider_endpoint, "?", params].join

    return curl_map_data(url)
  end

  def curl_map_data(url)
    @curl = @curl || Curl::Easy.new
    @curl.url = url

    retries = 0
    begin
      @curl.perform
      if @curl.response_code == 200
        return @curl.body_str
      else
        raise RetryException 
      end
    rescue RetryException => e
      retries += 1
      retry if retries < 3
      raise "Failed to download Google Static Map: " + url
    end
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
  
  def image_resource_of(lat, lng, room, map_type, marker)
    image_data = dump_static_map(lat, lng, room, map_type, marker)

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

  def attributes_of(lat, lng)
    attributes = Type::NoteAttributes.new
    attributes.latitude = lat.to_f
    attributes.longitude = lng.to_f

    return attributes
  end

  def update_attributes(note, opts)
    attr = opts[:attributes]
    note.attributes = note.attributes || Type::NoteAttributes.new
    note.attributes.latitude = note.attributes.latitude || attr.latitude
    note.attributes.longitude = note.attributes.longitude || attr.longitude
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

  def parse_request(params, type)
    lat, lng = params["lat"], params["lng"]
    zoom, map_type = params["zoom"], params["map_type"]
    marker = get_marker params
  
    logger.info "location='#{lat},#{lng},#{zoom}'"
  
    opts = {
      :resource => image_resource_of(lat, lng, zoom, map_type, marker),
      :attributes => attributes_of(lat, lng),
      :link => map_link(marker.lat, marker.lng, zoom)
    }
  
    case type
    when :create
      opts[:note_name] = params['note_name']
      create_note opts
    when :update
      opts[:guid] = params['id']
      update_note opts
    end
  end
  
  def update_note(opts)
    evernote_request do
      note = @note_store.getNote(opts[:guid], true, true, true, true)
      update_attributes(note, opts)
      note.resources = note.resources || []
      note.resources << opts[:resource]
      note.content.gsub!(/(?=<\/en-note>)/, image_content(opts[:resource], opts[:link]))
      @note_store.updateNote(note)
    end
  end
  
  def create_note(opts)
    evernote_request do
      new_note = Type::Note.new
      new_note.title = opts[:note_name]
      new_note.resources = [ opts[:resource] ]
      new_note.attributes = opts[:attributes]
      new_note.content = new_note_content(image_content(opts[:resource], opts[:link]))

      @note_store.createNote(new_note)
    end
  end

  def evernote_request(&task)
    begin
      note = task.call
      [200, {"note_url" => note_url(note)}]
    rescue Error::EDAMNotFoundException => nfe
      logger.error "NotFoundEeception:[#{nfe.identifier};#{nfe.key}]"
      [404, {"error" => "Note not found: #{nfe.key}"}]
    rescue Error::EDAMUserException => ue
      case ue.errorCode
      when Error::EDAMErrorCode::QUOTA_REACHED
        logger.error "User Quota Reached"
        [400, {"error" => "User Quota Reached"}]
      when Error::EDAMErrorCode::LIMIT_REACHED
        logger.error "Note Limit Reached"
        [400, {"error" => "Note Limit Reached"}]
      else
        logger.error "Other Error:#{ue.errorCode}"
        [400, {"error" => "Other Error", "code" => ue.errorCode}]
      end
    rescue Error::EDAMSystemException => se
      case se.errorCode
      when Error::EDAMErrorCode::RATE_LIMIT_REACHED
        logger.error "Rate Limit Reached"
        [400, {"error" => "Rate Limit Reached", "rateLimitDuration" => se.rateLimitDuration}]
      else
        logger.error "Other Error:#{ue.errorCode}"
        [400, {"error" => "Other Error"}]
      end
    end
  end

  def map_link(lat, lng, zoom)
    #"https://maps.google.com/maps?q=loc:#{lat},#{lng}&amp;z=#{zoom}"
    lat_dd = dd_of lat.to_f, :lat
    lng_dd = dd_of lng.to_f, :lng
    "https://www.google.com/maps/place/#{lat_dd}+#{lng_dd}/@#{lat},#{lng},#{zoom}z/"
  end

  def dd_of(dms, lat_or_lng)
    d = dms.abs.floor
    m = (dms.abs * 60).floor % 60
    s = dms.abs * 3600 % 60
    postfix = case lat_or_lng
    when :lat
     dms > 0 ? "N" : "S"
    when :lng
     dms > 0 ? "E" : "W"
    end
    URI.escape("%.f°%.f'%.1f\"%s" % [d, m, s, postfix])
  end

  def profile(msg)
    @start ||= Time.now
    logger.error "#{msg} ===> #{Time.now - @start}"
  end
end

before '/api/*' do
  if auth_token.nil? and params["auth_token"].nil?
    msg = "auth_token is invalid"
    logger.info msg
    halt 401, msg
  else
    @client = EvernoteOAuth::Client.new(
      token: auth_token || params["auth_token"],
      sandbox: SANDBOX
    )
    begin
      @note_store = @client.note_store
    rescue Error::EDAMUserException => e
      logger.error "auth token is expired"
      halt(401, "auth token is expired") if e.errorCode == Error::EDAMErrorCode::AUTH_EXPIRED
    rescue Error::EDAMSystemException => e
      logger.error "auth token is invalid"
      halt(401, "auth token is invalid") if e.errorCode == Error::EDAMErrorCode::INVALID_AUTH
    end
  end
end

get '/' do
  index_page = '/index.html'
  index_page += "?" + params.map { |k,v|
    "#{k}=#{v}" }.join("&") unless params.empty?
  redirect index_page
end

# get '/error' do
#   @last_error = "Request token not set."
#   erb :error
# end

get '/api/notes' do
  notes = []
  latest_notes(5).each do |note|
    notes << { "guid" => note.guid, "title" => note.title }
  end

  json :notes => notes 
end

# create a new note
post '/api/notes' do
  code, message = parse_request(params, :create)
  status code
  json message
end

# update a note
put '/api/notes/:id' do
  code, message = parse_request(params, :update)
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
    logger.error "Content owner did not authorize the temporary credentials"
    redirect '/oauth/reset'
  end

  begin
    access_token = request_token.get_access_token(
      :oauth_verifier => params[:oauth_verifier]
    )

    session.clear

    session[:auth_token] = access_token.token

    if params[:back_url]
      back_url = URI(params[:back_url])
      params = URI.decode_www_form(back_url.query || '') << ['auth_token', access_token.token]
      back_url.query = URI.encode_www_form(params)
      redirect back_url.to_s
    else
      redirect '/'
    end
  rescue => e
    warn e.message
    logger.error 'Error extracting access token'
    redirect '/oauth/reset'
  end
end

get '/oauth/reset' do
  session.clear
  redirect '/'
end
