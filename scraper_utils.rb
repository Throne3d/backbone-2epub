module ScraperUtils
  require 'fileutils'
  require 'open-uri'
  require 'open_uri_redirections'

  class FileLogIO
    attr_reader :file
    def initialize(defaultFile=nil)
      return unless defaultFile
      FileUtils::mkdir_p(File.dirname(defaultFile))
      @file = File.open(defaultFile, 'a+')
    end

    def file=(filename)
      @file.close if @file
      FileUtils::mkdir_p(File.dirname(filename))
      @file = File.open(filename, 'a+')
      @file.sync = true
    end

    def set_output_params(group, output=:epub)
      self.file = 'logs/' + Time.now.strftime('%Y-%m-%d %H %M ') + " #{output} #{group}.log"
    end

    def write(data); @file.try(:write, data); end
    def close; @file.try(:close); end
  end

  DEBUGGING = false

  CONSOLE = Logger.new(STDOUT)
  CONSOLE.formatter = proc { |_severity, _datetime, _progname, msg|
    "#{msg}\n"
  }
  CONSOLE.datetime_format = "%Y-%m-%d %H:%M:%S"

  OUTFILE = FileLogIO.new("logs/default.log")
  FILELOG = Logger.new(OUTFILE)
  FILELOG.datetime_format = "%Y-%m-%d %H:%M:%S"

  LOG = Object.new
  def LOG.debug(str)
    return unless DEBUGGING
    CONSOLE.debug(str) unless DEBUGGING == :file
    FILELOG.debug(str) if DEBUGGING == :file
  end
  def LOG.info(str)
    CONSOLE.info(str)
    FILELOG.info(str)
  end
  def LOG.warn(str)
    CONSOLE.warn(str)
    FILELOG.warn(str)
  end
  def LOG.error(str)
    CONSOLE.error(str)
    FILELOG.error(str)
  end
  def LOG.fatal(str)
    CONSOLE.fatal(str)
    FILELOG.fatal(str)
  end
  def LOG.progress(message=nil, progress=-1, count=-1)
    # e.g. "Saving chapters", 0, 300
    if progress < 0
      # end the progress!
      CONSOLE << "\n"
      LOG.info(message)
      return
    end

    perc = progress / count.to_f * 100
    CONSOLE << CONSOLE.formatter.call(Logger::Severity::INFO, Time.now, CONSOLE.progname, "\r#{message}… [#{progress}" + (count > 0 ? "/#{count}] #{perc.round}%" : "]")).chomp if CONSOLE.info?
  end

  FIC_TOCS = {
    #Continuities
    gwern: 'https://www.gwern.net/index'
  }

  FIC_AUTHORSTRINGS = {
    gwern: 'Gwern' # FIXME: update this
  }
  FIC_AUTHORSTRINGS.default = "Unknown"

  FIC_NAMESTRINGS = {
    gwern: 'Gwern' # FIXME: update this
  }
  FIC_NAMESTRINGS.default_proc = proc {|hash, key| hash[key] = key.titleize }

  def date_display(date, strf="%Y-%m-%d %H:%M")
    date.try(:strftime, strf)
  end

  def sanitize_local_path(local_path)
    local_path.gsub("\\", "~BACKSLASH~").gsub(":", "~COLON~").gsub("*", "~ASTERISK~").gsub("?", "~QMARK~").gsub("\"", "~QUOT~").gsub("<", "~LT~").gsub(">", "~GT~").gsub("|", "~BAR~")
  end

  def get_page_data(file_url)
    LOG.debug "get_page('#{file_url}')"

    retries = 3
    success = has_retried = false
    data = nil
    begin
      param_hash = {:ssl_verify_mode => OpenSSL::SSL::VERIFY_NONE, :allow_redirections => :all}
      data = open(file_url, param_hash) { |webpage| webpage.read }
      sleep 0.05
      success = true
    rescue OpenURI::HTTPError, SocketError, Net::OpenTimeout, Net::ReadTimeout => error
      LOG.error "Error loading file (#{file_url}); #{retries} retr#{retries==1 ? 'y' : 'ies'} left"
      LOG.debug error

      retries -= 1
      has_retried = true
      retry if retries >= 0
    end

    unless success
      LOG.error "Failed to load page (#{file_url})"
      return
    end

    LOG.debug "Got page"
    LOG.info "Successfully loaded file (#{file_url})." if has_retried
    data
  end

  def get_file(url, options={})
    path = options[:path] # required
    replace = options[:replace] # default off
    return if File.file?(path) && !replace

    data = get_page_data(url)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, 'w') { |f| f.write(data) }
    path
  end

  def standardize_url(url, from_url=nil)
    return url if url[/^https?:\/\//] # URL is fully-qualified
    from_uri = URI.parse(from_url)

    if url.start_with?('/') # URL is relative to root, return with that
      from_uri.path = url
      return from_uri.to_s
    end

    url = url.sub('./', '') if url.start_with?('./')
    (LOG.error "cannot handle ../ in standardize_url (#{url})"; return url) if url.start_with?('../')

    url = url.split('#').first # strip fragment

    # URL is relative file, remove last part from path & append
    from_uri.path = from_uri.path.sub(from_uri.path.split('/').last, '') + url
    from_uri.to_s
  end

  BLOCK_LEVELS = [:address, :article, :aside, :blockquote, :canvas, :dd, :div, :dl, :fieldset, :figcaption, :figure, :footer, :form, :h1, :h2, :h3, :h4, :h5, :h6, :header, :hgroup, :hr, :li, :main, :nav, :noscript, :ol, :output, :p, :pre, :section, :table, :tfoot, :ul, :video, :br]
  def get_text_on_line(node, options={})
    standardize_params(options)
    raise(ArgumentError, "Invalid parameter combo: :after and :forward") if options.key?(:after) && options.key?(:forward)
    raise(ArgumentError, "Invalid parameter combo: :before and :backward") if options.key?(:before) && options.key?(:backward)

    stop_at = options[:stop_at] || []
    stop_at = [stop_at] unless stop_at.is_a?(Array)

    forward = true
    forward = options[:forward] || options[:after] if options.key?(:forward) || options.key?(:after)

    backward = true
    backward = options[:backward] || options[:before] if options.key?(:backward) || options.key?(:before)

    include_node = options.key?(:include_node) ? options[:include_node] : true

    text = ''
    text = node.text if include_node

    previous_element = node.previous
    while backward && previous_element && !BLOCK_LEVELS.include?(previous_element.name) && !BLOCK_LEVELS.include?(previous_element.name.to_sym) && !stop_at.include?(previous_element.name) && !stop_at.include?(previous_element.name.to_sym)
      text = previous_element.text + text
      previous_element = previous_element.previous
    end

    next_element = node.next
    while forward && next_element && !BLOCK_LEVELS.include?(next_element.name) && !BLOCK_LEVELS.include?(next_element.name.to_sym) && !stop_at.include?(next_element.name) && !stop_at.include?(next_element.name.to_sym)
      text = text + next_element.text
      next_element = next_element.next
    end

    text
  end

  def standardize_params(params={})
    params.keys.each do |key|
      params[key.to_sym] = params.delete(key) if key.is_a?(String)
    end
    params
  end

  def sort_query(query)
    return if query.blank?

    query_hash = CGI::parse(query)
    sorted_keys = query_hash.keys.sort

    sorted_list = []
    sorted_keys.each do |key|
      sorted_list << [key, query_hash[key]]
    end
    sorted_query = URI.encode_www_form(sorted_list)

    return if sorted_query.empty?
    sorted_query
  end

  def set_url_params(chapter_url, params={})
    uri = URI(chapter_url)
    uri_query = uri.query || ''
    paramstr = URI.encode_www_form(params)
    uri_query += '&' unless uri_query.empty? || paramstr.empty?
    uri_query += paramstr

    uri.query = sort_query(uri_query)
    uri.to_s
  end

  def clear_url_params(chapter_url)
    uri = URI(chapter_url)
    uri.query = ''
    uri.to_s
  end

  def get_url_params_for(chapter_url, param_name)
    return if chapter_url.blank?
    uri = URI(chapter_url)
    return [] unless uri.query.present?
    query_hash = CGI::parse(uri.query)
    return [] unless query_hash.key?(param_name)
    query_hash[param_name]
  end
  def get_url_param(chapter_url, param_name, default=nil)
    return default if chapter_url.blank?
    params = get_url_params_for(chapter_url, param_name)
    params.first || default
  end
end
