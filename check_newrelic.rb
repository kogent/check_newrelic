#!/usr/bin/env ruby

require 'rubygems'
require 'httparty'
require 'getoptlong'

#Nagios return messages, these class methods exit with the appropriate exit code and message
class Nagios
  def self.ok msg=""
    puts "OK: #{msg}"
    exit 0
  end
  def self.warning msg=""
    puts "WARNING: #{msg}"
    exit 1
  end
  def self.critical msg=""
    puts "CRITICAL: #{msg}"
    exit 2
  end
  def self.unknown msg=""
    puts "UNKNOWN: #{msg}"
    exit 3
  end
  # return nagios plugin formatted perfdata using following format:
  # 'label'=value[UOM];[warn];[crit];[min];[max]
  def self.perf_data label, metric_value, warn, crit
    "#{label}=#{metric_value};#{warn};#{crit};;"
  end
end

# NewRelicApi class wraps the NewRelic API and parses results
class NewRelicApi
  include HTTParty
  base_uri 'rpm.newrelic.com'

  def self.set_api_key api_key
    headers 'x-license-key' => api_key
  end

  #unused in plugin, gets account data
  def self.get_account
    get("/accounts.xml")
  end

  #unused in plugin, gets array of applications
  def self.get_applications account_id
    get("/accounts/#{account_id}/applications.xml")
  end

  #gets current metric summary of all applications
  def self.get_metrics
    get("/accounts.xml?include=application_health")
  end
  
  # return a nested hash keyed first by application name then by metric name
  def self.parse_data results
    metrics = {}
    apps = results["accounts"][0]["applications"]
    apps.each do |result_set|
      metrics[result_set["name"]] = {}
      result_set["threshold_values"].each do |threshold_value|
         metrics[result_set["name"]].merge!( {threshold_value["name"] => threshold_value }) 
      end
    end
    metrics
  end
  
end


#TODO: output command line help
def usage
  puts <<-EOH
    check_newrelic.rb  [-w <warning_threshold>]
                       [-c <critical_threshold>]
                       [--app | -a <application_name>]
                       [--metric | -m <cpu|memory|errors|response|throughput|db>]
                       [--api-key | -k <newrelic api key>]
                       [--debug | -d]
                       [--help | -h]
  EOH
end

#TODO: grab ENV vars if present

opts = GetoptLong.new(
  [ "--help", "-h",GetoptLong::NO_ARGUMENT],
  [ "-w", GetoptLong::REQUIRED_ARGUMENT],
  [ "-c", GetoptLong::REQUIRED_ARGUMENT],
  [ "--app", "-a", GetoptLong::REQUIRED_ARGUMENT],
  [ "--metric", "-m", GetoptLong::REQUIRED_ARGUMENT],
  [ "--api-key", "-k", GetoptLong::REQUIRED_ARGUMENT],
  [ "--debug", "-d", GetoptLong::NO_ARGUMENT]
  )

$debug = false
METRIC_TYPES = %w'cpu memory errors response throughput db'
@warning_threshold = 0
@critical_threshold = 0

opts.each do |opt,arg|
  case opt
    when '--help'
      usage
      exit 0
    when '-w'
      @warning_threshold = arg
    when '-c'
      @critical_threshold = arg
    when '--app'
      @application_name = arg
    when '--metric'
      Nagios.unknown "Invalid argument for #{opt}" unless METRIC_TYPES.include? arg.downcase
      #format metric types to match those returned by NewRelic API
      if arg.downcase == "response"
        @metric = "Response Time"
      else
        @metric = arg.capitalize
      end
    when '--api-key'
      @api_key = arg
    when '--debug'
      require 'PP'
      puts "DEBUG FLAG SET"
      $debug = true
  end
end

puts "warning_threshold = #{@warning_threshold}" if $debug
puts "critical_threshold = #{@critical_threshold}" if $debug
puts "application_name = #{@application_name}" if $debug
puts "metric = #{@metric}" if $debug
puts "api_key = #{@api_key}" if $debug

#Check to make sure neccessary flags are set
%w'application_name metric api_key'.each do |var|
  Nagios.unknown "Unspecified argument for #{var}" unless eval "defined? @#{var}"
end

# now that api_key has been given add it to NewRelicApi class
NewRelicApi.set_api_key @api_key

#Get metrics from NewRelic
results = NewRelicApi.get_metrics
if $debug
  puts "API Query results: "
  pp results
end

#Check if valid api_key
Nagios.unknown "Invalid NewRelic API key" if results.code == 500

#parse results into useable hash
parsed_data = NewRelicApi.parse_data(results)
if $debug
  puts "Parsed results: "
  pp parsed_data
end
#Check if valid application name
unless parsed_data.member? @application_name
  Nagios.unknown "Invalid application name for --app" 
end

#grab the metric being queried
metric_value = parsed_data[@application_name][@metric]['formatted_metric_value'].to_i

label = "#{@application_name.split(" ").join("_")}_#{@metric.split(" ").join("_")}"

#format the perfdata
perf_data = Nagios.perf_data(
                          label,
                          metric_value, 
                          @warning_threshold, 
                          @critical_threshold) 
puts "Perf Data: #{perf_data}" if $debug

#Crit if beyond critical threshold
if metric_value > @critical_threshold
  Nagios.critical "#{metric_value} returned for #{@metric} exceeds threshold of #{@critical_threshold} #{perf_data}"
end

#Warn if beyond warning threshold
if metric_value > @warning_threshold
  Nagios.warning "#{metric_value} returned for #{@metric} exceeds threshold of #{@warning_threshold} #{perf_data}"
end

#if not warn or critical, must be ok
Nagios.ok "#{metric_value} returned for #{@metric} | #{perf_data}"

#Should never get this far
Nagios.unknown "something failed"
