module Scraper
  module IndexHandlers
    require 'scraper_utils'
    include ScraperUtils

    INDEX_PRESETS = {}

    def self.for(thing)
      index_handlers = Scraper::IndexHandlers.constants.map {|c| Scraper::IndexHandlers.const_get(c) }
      index_handlers.select! {|c| c.is_a?(Class) && c < Scraper::IndexHandlers::IndexHandler }
      chapter_handlers = index_handlers.select {|c| c.handles? thing}
      return chapter_handlers.first if chapter_handlers.length == 1
      chapter_handlers
    end

    class IndexHandler
      attr_accessor :group
      def initialize(options = {})
        self.group = options[:group]
      end

      def self.handles(*args)
        @handles = args
      end
      def self.handles?(thing)
        return unless @handles
        @handles.include?(thing)
      end
      def handles?(thing)
        self.handles?(thing)
      end

      def toc_url
        FIC_TOCS[group]
      end
    end

    class GwernHandler < IndexHandler
      handles :gwern

      def handle_ul(ul, section_list, header_name='h1')
        header = ul.previous_element
        (LOG.error "not a #{header_name}: #{header}"; return) unless header.name == header_name
        section_list = section_list + [header.text.strip]

        ul.css('li').each do |li|
          yield(li, section_list)
        end
      end

      def handle_link(a, section_list)
        url = standardize_url(a[:href], toc_url)
        if url == "https://www.gwern.net/In%20Defense%20of%20Inclusionism"
          url = "https://www.gwern.net/In%20Defense%20Of%20Inclusionism"
        end
        yield({url: url, name: a.text.strip, data: get_page_data(url), sections: section_list})
      end

      def each_page(&block)
        # fetch each page url, name, data, sections
        toc = get_page_data(toc_url)
        toc = Nokogiri::HTML(toc)
        content = toc.at_css('#content')
        uls = content.css('section > ul')

        uls.each do |ul|
          handle_ul(ul, []) do |li, section_list|
            if (ul2 = li.at_css('ul'))
              handle_ul(ul2, section_list, 'p') do |li2, section_list2|
                handle_link(li2.at_css('a'), section_list2, &block)
              end
              next
            end
            handle_link(li.at_css('a'), section_list, &block)
          end
        end
      end
    end
  end
end
