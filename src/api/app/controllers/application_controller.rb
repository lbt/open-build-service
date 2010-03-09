# Filters added to this controller will be run for all controllers in the application.
# Likewise, all the methods added will be available for all controllers.

require 'ldap'
require 'opensuse/permission'
require 'opensuse/backend'
require 'opensuse/validator'
require 'xpath_engine'
require 'rexml/document'

class InvalidHttpMethodError < Exception; end

class ApplicationController < ActionController::Base

  # Do never use a layout here since that has impact on every
  # controller in frontend
  layout nil
  # session :disabled => true

  @user_permissions = nil
  @http_user = nil
  
  #session options for tag admin
  #session_options[:sort] ||= "ASC"
  #session_options[:column] ||= "id"
  
  helper RbacHelper
 
  before_filter :validate_incoming_xml 

  # skip the filter for the user stuff
  before_filter :extract_user, :except => :register
  before_filter :setup_backend, :add_api_version, :restrict_admin_pages
  before_filter :shutup_rails

  #contains current authentification method, one of (:ichain, :basic)
  attr_accessor :auth_method

  def restrict_admin_pages
    if params[:controller] =~ /^active_rbac/ or params[:controller] =~ /^admin/
      return require_admin
    end
  end

  def require_admin
    logger.debug "Checking for  Admin role for user #{@http_user.login}"
    unless @http_user.has_role? 'Admin'
      logger.debug "not granted!"
      render :template => 'permerror'
      return false
    end
    return true
  end

  def extract_user
    @http_user = nil

    if ichain_mode != :off # configured in the the environment file
      @auth_method = :ichain

      logger.debug "configured iChain mode: #{ichain_mode.to_s},  remote_ip: #{request.remote_ip()}"

      ichain_user = request.env['HTTP_X_USERNAME']

      if ichain_user 
        logger.info "iChain user extracted from header: #{ichain_user}"
      else
# TEST vv
        if ichain_mode == :simulate
          ichain_user = ichain_test_user 
          logger.debug "TEST-ICHAIN_USER #{ichain_user} set!"
        end
        request.env.each do |name, val|
          logger.debug "Header value: #{name} = #{val}"
        end
# TEST ^^
      end
      # ok, we're using iChain. So there is no need to really
      # authenticate the user from the credentials coming via
      # basic auth header field. We can trust the username coming from
      # iChain
      # However we have to care for the status of the user that must not be
      # unconfirmed or ichain requested
      if ichain_user 
        @http_user = User.find :first, :conditions => [ 'login = ? AND state=2', ichain_user ]
        @http_user.update_email_from_ichain_env(request.env) unless @http_user.nil?

        # If we do not find a User here, we need to create a user and wait for 
        # the confirmation by the user and the BS Admin Team.
        if @http_user == nil 
          @http_user = User.find :first, 
                                   :conditions => ['login = ?', ichain_user ]
          if @http_user == nil
            render_error :message => "iChain user not yet registered", :status => 403,
                         :errorcode => "unregistered_ichain_user",
                         :details => "Please register your iChain user via the web application once."
          else
            if @http_user.state == 5
              render_error :message => "iChain user #{ichain_user} is registered but not yet approved.", :status => 403,
                           :errorcode => "registered_ichain_but_unapproved",
                           :details => "<p>Your account is a registered iChain account, but it is not yet approved for the buildservice.</p>"+
                                       "<p>Please stay tuned until you get approval message.</p>"
            else
              render_error :message => "Your user is either invalid or net yet confirmed (state #{@http_user.state}).", 
                           :status => 403,
                           :errorcode => "unconfirmed_user",
                           :details => "Please contact the openSUSE admin team <admin@opensuse.org>"
            end
          end
          return false
        end
      else
        logger.error "No X-username header from iChain! Are we really using iChain?"
        render_error( :message => "No iChain user found!", :status => 401 ) and return false
      end
    else 
      #active_rbac is used for authentication
      @auth_method = :basic

      if request.env.has_key? 'X-HTTP_AUTHORIZATION' 
        # try to get it where mod_rewrite might have put it 
        authorization = request.env['X-HTTP_AUTHORIZATION'].to_s.split 
      elsif request.env.has_key? 'Authorization' 
        # for Apace/mod_fastcgi with -pass-header Authorization 
        authorization = request.env['Authorization'].to_s.split 
      elsif request.env.has_key? 'HTTP_AUTHORIZATION' 
        # this is the regular location 
        authorization = request.env['HTTP_AUTHORIZATION'].to_s.split  
      end 
  
      logger.debug( "AUTH: #{authorization}" )
  
      if authorization and authorization[0] == "Basic"
        # logger.debug( "AUTH2: #{authorization}" )
        login, passwd = Base64.decode64(authorization[1]).split(':')[0..1]
        
        #set password to the empty string in case no password is transmitted in the auth string
        passwd ||= ""
      else
        logger.debug "no authentication string was sent"
        render_error( :message => "Authentication required", :status => 401 ) and return false
      end
      
      # disallow empty passwords to prevent LDAP lockouts
      if !passwd or passwd == ""
        render_error( :message => "User '#{login}' did not provide a password", :status => 401 ) and return false
      end
      
      if defined?( LDAP_MODE ) && LDAP_MODE == :on
        logger.debug( "Using LDAP to find #{login}" )
        ldap_info = User.find_with_ldap( login, passwd )
        if not ldap_info.nil?
          # We've found an ldap authenticated user - find or create an OBS userDB entry.
          @http_user = User.find :first, :conditions => [ 'login = ?', login ]
          if @http_user
            # Check for ldap updates
            if @http_user.email != ldap_info[0]
              @http_user.email = ldap_info[0]
              @http_user.save
            end
          else
            logger.debug( "No user found in database, creating" )
            logger.debug( "Email: #{ldap_info[0]}" )
            logger.debug( "Name : #{ldap_info[1]}" )
            # Generate and store a fake pw in the OBS DB that no-one knows
            chars = ["A".."Z","a".."z","0".."9"].collect { |r| r.to_a }.join
            fakepw = (1..24).collect { chars[rand(chars.size)] }.pack("C*")
            newuser = User.create(
            :login => login,
            :password => fakepw,
            :password_confirmation => fakepw,
            :email => ldap_info[0] )
            unless newuser.errors.empty?
              errstr = String.new
              logger.debug("Creating User failed with: ")
              newuser.errors.each_full do |msg|
                errstr = errstr+msg
                logger.debug(msg)
              end
              render_error( :message => "Cannot create ldap userid: '#{login}' on OBS<br>#{errstr}",
                            :status => 401 ) and return false
              @http_user=nil
              return false
            end
            newuser.realname = ldap_info[1]
            newuser.state = User.states['confirmed']
            newuser.adminnote = "User created via LDAP"
            user_role = Role.find_by_title("User")
            newuser.roles << user_role

            logger.debug( "saving new user..." )
            newuser.save

            @http_user = newuser
          end
          
          session[:rbac_user_id] = @http_user.id
        else
          logger.debug( "User not found with LDAP, falling back to database" )
          @http_user = User.find_with_credentials login, passwd
        end

      else
        @http_user = User.find_with_credentials login, passwd
      end
    end

    if @http_user.nil?
      render_error( :message => "Unknown user '#{login}' or invalid password", :status => 401 ) and return false
    else
      logger.debug "USER found: #{@http_user.login}"
      @user_permissions = Suse::Permission.new( @http_user )
    end
  end

  def setup_backend
    # initialize backend on every request
    Suse::Backend.source_host = SOURCE_HOST
    Suse::Backend.source_port = SOURCE_PORT
    
    if @http_user
      if @http_user.source_host && !@http_user.source_host.empty?
        Suse::Backend.source_host = @http_user.source_host
      end

      if @http_user.source_port
        Suse::Backend.source_port = @http_user.source_port
      end

      logger.debug "User's source backend <#{@http_user.source_host}:#{@http_user.source_port}>"
    end
  end

  def add_api_version
    response.headers["X-Opensuse-APIVersion"] = API_VERSION
  end

  def forward_data( path, opt={} )
    defaults = {:server => :source, :method => :get}
    opt = defaults.merge opt

    case opt[:method]
    when :get
      response = Suse::Backend.get_source( path )
    when :post
      response = Suse::Backend.post_source( path, request.raw_post )
    when :put
      response = Suse::Backend.put_source( path, request.raw_post )
    when :delete
      response = Suse::Backend.delete_source( path )
    end

    send_data( response.body, :type => response.fetch( "content-type" ),
      :disposition => "inline" )
  end

  def rescue_action_locally( exception )
    rescue_action_in_public( exception )
  end

  def rescue_action_in_public( exception )
    #FIXME: not all exceptions are caught by this method
    case exception
    when ::Suse::Backend::HTTPError

      xml = REXML::Document.new( exception.message.body )
      http_status = xml.root.attributes['code']

      unless xml.root.attributes.include? 'origin'
        xml.root.add_attribute "origin", "backend"
      end

      xml_text = String.new
      xml.write xml_text

      render :text => xml_text, :status => http_status
    when ActiveXML::Transport::NotFoundError
      render_error :message => exception.message, :status => 404
    when Suse::ValidationError
      render_error :message => "XML validation failed", :details => exception.message , :status => 400
    when InvalidHttpMethodError
      render_error :message => exception.message, :errorcode => "invalid_http_method", :status => 400
    when DbPackage::SaveError
      render_error :message => "error saving package: #{exception.message}", :errorcode => "package_save_error", :status => 400
    when DbProject::SaveError
      render_error :message => "error saving project: #{exception.message}", :errorcode => "project_save_error", :status => 400
    when ActionController::RoutingError
      render_error :message => exception.message, :status => 404, :errorcode => "not_found"
    when ActionController::UnknownAction
      render_error :message => exception.message, :status => 403, :errorcode => "unknown_action"
    else
      if send_exception_mail?
        ExceptionNotifier.deliver_exception_notification(exception, self, request, {})
      end
      render_error :message => "uncaught exception: #{exception.message}", :status => 400
    end
  end

  def send_exception_mail?
    return false unless ExceptionNotifier.exception_recipients
    return !local_request? && !Rails.env.development?
  end

  def permissions
    return @user_permissions
  end

  def user
    return @http_user
  end

  def valid_http_methods(*methods)
    list = methods.map {|x| x.to_s.downcase.to_s}
    unless methods.include? request.method
      raise InvalidHttpMethodError, "Invalid HTTP Method: #{request.method.to_s.upcase}"
    end
  end

  def render_error( opt = {} )
    if opt[:status]
      if opt[:status].to_i == 401
        response.headers["WWW-Authenticate"] = 'basic realm="API login"'
      end
    else
      opt[:status] = 400
    end
    
    @exception = opt[:exception]
    @details = opt[:details]

    @summary = "Internal Server Error"
    if opt[:message]
      @summary = opt[:message]
    elsif @exception
      @summary = @exception.message 
    end
    
    if opt[:errorcode]
      @errorcode = opt[:errorcode]
    elsif @exception
      @errorcode = 'uncaught_exception'
    else
      @errorcode = 'unknown'
    end

    # if the exception was raised inside a template (-> @template.first_render != nil), 
    # the instance variables created in here will not be injected into the template
    # object, so we have to do it manually
# This is commented out, since it does not work with Rails 2.3 anymore and is also not needed there
#    if @template.first_render
#      logger.debug "injecting error instance variables into template object"
#      %w{@summary @errorcode @exception}.each do |var|
#        @template.instance_variable_set var, eval(var) if @template.instance_variable_get(var).nil?
#      end
#    end

    # on some occasions the status template doesn't receive the instance variables it needs
    # unless render_to_string is called before (which is an ugly workaround but I don't have any
    # idea where to start searching for the real problem)
    render_to_string :template => 'status'

    logger.info "errorcode '#@errorcode' - #@summary"
    response.headers['X-Opensuse-Errorcode'] = @errorcode
    render :template => 'status', :status => opt[:status], :layout => false
  end
  
  def render_ok(opt={})
    # keep compatible to old call style
    opt = {:details => opt} if opt.kind_of? String
    
    @errorcode = "ok"
    @summary = "Ok"
    @details = opt[:details] if opt[:details]
    @data = opt[:data] if opt[:data]
    render :template => 'status', :status => 200, :layout => false
  end
  
  def backend
    @backend ||= ActiveXML::Config.transport_for :bsrequest
  end

  def backend_get( path )
    # TODO: check why not using SUSE:Backend::get
    backend.direct_http( URI(path) )
  end

  def backend_put( path, data )
    backend.direct_http( URI(path), :method => "PUT", :data => data )
  end

  def backend_post( path, data )
    backend.set_additional_header("Content-Length", data.size.to_s())
    response = backend.direct_http( URI(path), :method => "POST", :data => data )
    backend.delete_additional_header("Content-Length")
    return response
  end

  #default actions, passes data from backend
  def pass_to_backend
    begin
       forward_data request.path+'?'+request.query_string, :server => :source
    rescue Suse::Backend::HTTPError
       render_error :status => 404, :errorcode => "not found",
        :message => "#{request.path} not found"
    end
  end
  alias_method :pass_to_source, :pass_to_backend

  def ichain_mode
      ICHAIN_MODE
  end
  
  def ichain_test_user
      ICHAIN_TEST_USER
  end

  # Passes control to subroutines determined by action and a request parameter. By 
  # default the parameter assumed to contain the command is ':cmd'. Looks for a method
  # named <action>_<command>
  #
  # Example:
  #
  # If you call dispatch_command from an action 'index' with the query parameter cmd
  # having the value 'show', it will call the method 'index_show'
  #
  def dispatch_command(opt={})
    defaults = {
      :cmd_param => :cmd
    }
    opt = defaults.merge opt
    unless params.has_key? opt[:cmd_param]
      render_error :status => 400, :errorcode => "missing_parameter'",
        :message => "missing parameter '#{opt[:cmd_param]}'"
      return
    end

    cmd_handler = "#{params[:action]}_#{params[opt[:cmd_param]]}"
    logger.debug "dispatch_command: trying to call method '#{cmd_handler}'"

    if not self.respond_to? cmd_handler, true
      render_error :status => 400, :errorcode => "unknown_command",
        :message => "Unknown command '#{params[opt[:cmd_param]]}' for path #{request.path}"
      return
    end

    __send__ cmd_handler
  end

  def esc(*args)
    CGI.escape *args
  end

  def uesc(*args)
    URI.escape *args
  end

  def build_query_from_hash(hash, key_list=nil)
    key_list ||= hash.keys
    query = key_list.map do |key|
      [hash[key]].flatten.map {|x| "#{key}=#{esc hash[key].to_s}"}.join("&") if hash.has_key?(key)
    end

    if query.empty?
      return ""
    else
      return "?"+query.compact.join('&')
    end
  end

  def query_parms_missing?(*list)
    missing = Array.new
    for param in list
      missing << param unless params.has_key? param
    end

    if missing.length > 0
      render_error :status => 400, :errorcode => "missing_query_parameters",
        :message => "missing query parameters: #{missing.join ', '}"
    end
    return false
  end

  def min_votes_for_rating
    MIN_VOTES_FOR_RATING
  end

  def shutup_rails
    Rails.cache.silence!
  end

  def action_fragment_key( options )
    # this is for customizing the path/filename of cached files (cached by the
    # action_cache plugin). here we want to include params in the filename
    par = params
    par.delete 'controller'
    par.delete 'action'
    pairs = []
    par.sort.each { |pair| pairs << pair.join('=') }
    url_for( options ).split('://').last + "/"+ pairs.join(',').gsub(' ', '-')
  end
end
