module Scraper
  module SiteHandlers
    require 'scraper_utils'
    require 'mechanize'
    include ScraperUtils

    def self.for(thing)
      site_handlers = Scraper::SiteHandlers.constants.map {|c| Scraper::SiteHandlers.const_get(c) }
      site_handlers.select! {|c| c.is_a?(Class) && c < Scraper::SiteHandlers::SiteHandler }
      chapter_handlers = site_handlers.select {|c| c.handles? thing}
      return chapter_handlers.first if chapter_handlers.length == 1
      chapter_handlers
    end

    class SiteHandler
      attr_accessor :group

      def initialize(options = {})
        self.group = options[:group]
      end

      def self.handles?(_chapter); false; end
      def handles?(chapter); self.class.handles?(chapter); end
    end

    class GwernHandler < SiteHandler
      attr_reader :download_count
      def self.handles?(thing)
        return if thing.nil?
        url = (thing.is_a?(Hash)) ? thing[:url] : thing
        return if url.blank?
        uri = URI.parse(url)
        uri.host.end_with?('gwern.net')
      end

      def parse(page)
        # use the page[:data] and nokogiri to fetch data from the page
        data = page[:data]
        data = Nokogiri::HTML(data) if data.is_a?(String)

        parsed_data = {}
        parsed_data[:meta] = data.at_css('#metadata').inner_html
        parsed_data[:body] = data.at_css('#markdownBody').inner_html

        LOG.info "Parsed: #{page[:name]}"
        parsed_data
      end
    end
  end
end
