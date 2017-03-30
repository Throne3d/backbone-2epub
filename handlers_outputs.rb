module Scraper
  module OutputHandlers
    require 'scraper_utils'
    require 'uri'
    require 'erb'
    include ScraperUtils

    def self.for(thing)
      output_handlers = Scraper::OutputHandlers.constants.map {|c| Scraper::OutputHandlers.const_get(c) }
      output_handlers.select! {|c| c.is_a?(Class) && c < Scraper::OutputHandlers::OutputHandler }
      chapter_handlers = output_handlers.select {|c| c.handles? thing}
      return chapter_handlers.first if chapter_handlers.length == 1
      chapter_handlers
    end

    class OutputHandler
      include ScraperUtils
      attr_accessor :group
      def initialize(options={})
        self.group = options[:group]
      end

      def self.handles?(_thing); false; end
      def handles?(thing); self.class.handles?(thing); end
    end

    class EpubHandler < OutputHandler
      include ERB::Util
      attr_accessor :nav, :images

      def self.handles?(output); output == :epub; end

      def initialize(options={})
        super options
        require 'eeepub'

        @folder_name = group.to_s

        @mode_folder = File.join('output', 'epub')
        @group_folder = File.join(@mode_folder, @folder_name)
        @style_folder = File.join(@group_folder, 'style')
        @html_folder = File.join(@group_folder, 'html')
        @images_folder = File.join(@group_folder, 'images')
        FileUtils::mkdir_p @style_folder
        FileUtils::mkdir_p @html_folder
        FileUtils::mkdir_p @images_folder

        @images = {}

        self.nav = []
        # structure:
        # [{label: section_name, nav: more_nav}, {label: page_name, content: relative_path}]
      end

      def style_path
        return @style_path if @style_path
        @style_path = File.join(@style_folder, 'default.css')
        open('style.css', 'r') do |style|
          open(style_path, 'w') do |css|
            css.write style.read
          end
        end
        @style_path
      end
      def toc_path;
        File.join(@group_folder, 'toc.html')
      end

      # relative_outside_file => relative_inside_folder
      # i.e. path => dirname(path_relative)
      def files; @files ||= [{style_path => 'EPUB/style'}]; end
      def template; @template ||= open("template_#{group}.erb") { |file| file.read }; end

      def get_page_path_bit(page)
        url = (page.is_a?(Hash)) ? page[:url] : page
        uri = URI.parse(url)
        uri.path = uri.path[0..-2] if uri.path.end_with?('/')
        uri.path += '.html' unless uri.path.split('/').last['.']
        uri.host + '-' + URI.decode(uri.path).gsub('/', '-')
      end
      def get_page_path(page)
        File.join(@html_folder, get_page_path_bit(page))
      end
      def get_page_path_relative(page)
        File.join('EPUB', 'html', get_page_path_bit(page))
      end

      # also downloads image and saves it to path, if necessary
      def get_image_path(url)
        return @images[url] if @images.key?(url)
        uri = URI.parse(url)
        path_bit = uri.host + '-' + URI.decode(uri.path).gsub('/', '-')
        path = File.join(@images_folder, path_bit)
        path_relative = File.join('EPUB', 'images', path_bit)
        get_file(url, path: path)
        files << {path => File.dirname(path_relative)}
        @images[url] = File.join('..', 'images', path_bit)
      end

      def html_from_navarray(navbits)
        if navbits.is_a?(Array)
          html = "<ol>\n"
          navbits.each do |navbit|
            html << html_from_navarray(navbit)
          end
          html << "</ol>\n"
          html = '' if html.gsub("\n", '') == "<ol></ol>"
          return html
        end

        html = "<li>"
        if navbits.key?(:nav)
          html << h(navbits[:label]) + "\n"
          html << html_from_navarray(navbits[:nav])
        else
          html << "<a href='" << URI.encode(navbits[:content].sub(/^EPUB(\/|\\)/, '')) << "'>#{h(navbits[:label])}</a>"
        end
        html << "</li>\n"
        html = '' if html.gsub("\n", '') == "<li></li>"
        html
      end

      def get_nav_for(sections, present=nil)
        present ||= nav
        return present if sections.blank?

        future = present.detect { |elem| elem[:label] == sections.first }
        unless future
          future = {label: sections.first, nav: []}
          nav << future
        end
        get_nav_for(sections[1..-1], future[:nav])
      end

      def add(page, parsed_data)
        # add to current list of things
        @page = page
        @parsed_data = parsed_data
        erb = ERB.new(template, 0, '-')
        b = binding
        html_result = erb.result b

        giri = Nokogiri::HTML(html_result)

        count = 0
        giri.css('img').each do |img_element|
          img_src = standardize_url(img_element[:src], page[:url])
          next unless img_src && img_src[/^https?:\/\//]
          img_element[:src] = get_image_path(img_src)
          count += 1
          LOG.progress('Getting images', count)
        end
        LOG.progress("Got #{count} image#{'s' unless count == 1}") if count > 0

        save_path = get_page_path(page)
        relative_path = get_page_path_relative(page)
        FileUtils.mkdir(File.dirname(save_path)) unless File.directory?(File.dirname(save_path))
        open(save_path, 'w') do |file|
          file.write giri.to_xhtml(indent_text: '', encoding: 'UTF-8')
        end
        files << {save_path => File.dirname(relative_path)}

        get_nav_for(page[:sections]) << {label: page[:name], content: relative_path}

        LOG.info "Added to output: #{page[:name]}"

        html_result
      end

      def done!
        # save! all the things! and do an EPUB!
        open(toc_path, 'w') do |toc|
          toc.write html_from_navarray(nav)
        end
        files << {toc_path => '/'}

        files.each do |file_set|
          file_set.keys.each do |file|
            next if file[0] == '/'
            file_set[File.join(Dir.pwd, file)] = file_set.delete(file)
          end
        end

        uri = URI.parse(FIC_TOCS[group])
        group = self.group
        files = @files
        nav = @nav
        epub = EeePub.make do
          title FIC_NAMESTRINGS[group]
          creator FIC_AUTHORSTRINGS[group]
          publisher (uri.host || '')
          date DateTime.now.strftime('%Y-%m-%d')
          identifier FIC_TOCS[group], scheme: 'URL'
          uid "scraped-#{group}"

          files files
          nav nav
        end
        epub_path = File.join(@mode_folder, "#{group}.epub")
        epub.save(epub_path)
      end
    end
  end
end
