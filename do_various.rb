#!/usr/bin/env ruby
require 'rubygems'
require 'bundler/setup'
require 'logger'
require 'active_support'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/object/try'
require 'active_support/core_ext/numeric/time'
require 'active_support/core_ext/string'
require 'active_support/time_with_zone'
require 'active_support/json'
require 'pry'
require 'ostruct'

$LOAD_PATH << '.'
$LOAD_PATH << File.dirname(__FILE__)
require 'scraper_utils'
require 'handlers_indexes'
require 'handlers_sites'
require 'handlers_outputs'
include ScraperUtils

FileUtils.mkdir "logs" unless File.directory?("logs")

set_trace_func proc {
  |event, _file, _line, _id, _binding, _classname|
  if event == "call" && caller_locations.length > 500
    fail "stack level too deep"
  end
}

class Array
  def contains_all? other
    other = other.dup
    each {|e| i = other.index(e); if i then other.delete_at(i) end }
    other.empty?
  end
  def delete_once(value)
    i = index(value)
    delete_at(i) if i
  end
  def delete_once_if(&block)
    delete_once(detect(&block))
  end
end

def usage(s=nil)
  usage_str = <<HEREDOC
Usage: #{File.basename($0)}:

No arguments. Will download gwern's works and create an EPUB of them.
HEREDOC

  if __FILE__ == $0
    $stderr.puts s unless s.nil?
    $stderr.puts usage_str
    abort
  else
    raise ArgumentError("args", s || "Invalid args passed.")
  end
end

# Returns the value from args for the appropriate shortarg or longarg
# Defaults to default
# examples:
# get_arg(['-p', 'value'], '-p', '--process') #=> 'value'
# get_arg(['--process', 'value'], '-p', '--process') #=> 'value'
# get_arg(['--test', 'value'], '-p', '--process') #=> nil
# get_arg(['--test', 'value'], '-p', '--process', false) #=> false
# Removes the appropriate shortarg/longarg & value pair from the array.
def get_arg(args, shortarg, longarg, default=nil)
  argname_bit = args.detect{|arg| (!shortarg.nil? && arg.start_with?(shortarg)) || arg =~ /^#{Regexp.escape(longarg)}\b/}
  arg_val = nil
  if argname_bit
    arg_index = args.index(argname_bit)
    arg_val =
      if argname_bit['=']
        argname_bit.split('=',2).last
      elsif argname_bit[' ']
        argname_bit.split(' ',2).last
      else
        temp_val = args[arg_index+1]
        if temp_val.nil? || !temp_val.start_with?('-')
          # if the value is nil, or it's not another argument
          args.delete_at(arg_index+1)
        else
          # if it's another argument
          true
        end
      end
    args.delete_at(arg_index)
  end
  # LOG.debug "get_arg got #{arg_val.inspect} for #{shortarg}, #{longarg}, default: #{default}"
  return arg_val || default
end

# Returns the first argument from args that isn't guarded by a flag (short or long)
# Defaults to default
# examples:
# get_unguarded_arg(['-p', 'test', 'thing']) #=> 'thing'
# get_unguarded_arg(['-p', 'test']) #=> nil
# get_unguarded_arg(['-p', 'test'], false) #=> false
# get_unguarded_arg(['val', '-p', 'test']) #=> 'val'
# get_unguarded_arg(['--process=test', 'val']) #=> 'val'
def get_unguarded_arg(args, default=nil)
  guarded = false
  arg = args.delete_once_if do |i|
    (guarded = false; next) if guarded
    if i =~ /^--?[\w\-]+/
      (guarded = true; next) unless i['='] || i[' ']
    end
    !guarded
  end
  # LOG.debug "get_unguarded_arg got #{arg.inspect}"
  # finds the first parameter that's not an argument, or that's not
  # directly after an argument that lacks "=" and " ".
  arg || default
end

# PROCESSES = {}

# Parses a list of arguments into an option structure.
def parse_args(args)
  args = [args] if args.is_a?(String)
  usage("Invalid arguments.") unless args && args.is_a?(Array)

  options = OpenStruct.new

  args = args.map(&:to_s).map(&:downcase)

  options.extras = args
  options
end

def main(*args)
  args = args.first if args.is_a?(Array) && args.first.is_a?(Array)
  options = parse_args(args)

  # TODO: maybe don't hard-code, add more things.
  options.group = :gwern
  options.output = :epub

  group = options.group
  output = options.output
  OUTFILE.set_output_params(group, output)

  # LOG.info "Other params: #{args}" if args.present?
  # LOG.info "-" * 60

  index_parser = Scraper::IndexHandlers.for(group).new(group: group)
  output_handler = Scraper::OutputHandlers.for(output).new(group: group)
  site_parsers = {}

  old_sections = []
  index_parser.each_page do |page|
    LOG.info "Section: #{page[:sections] * ' > '}" unless page[:sections] == old_sections
    old_sections = page[:sections]
    LOG.info "Indexed page: #{page[:name]}"
    parser = Scraper::SiteHandlers.for(page)
    site_parsers[parser] ||= parser.new(group: group)
    site_parser = site_parsers[parser]

    parsed_data = site_parser.parse(page)
    output_handler.add(page, parsed_data)
  end
  output_handler.done!
end

if __FILE__ == $0
  main(ARGV)
end
