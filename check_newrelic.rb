#!/usr/bin/env ruby
# Copyright (c) 2009 Mark Carey
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# check_newrelic.rb  [-w <warning_threshold>]
#                    [-c <critical_threshold>]
#                    [--app | -a <application_name>]
#                    [--metric | -m <cpu|memory|errors|response|throughput|db>]
#                    [--api-key | -k <newrelic api key>]
#                    [--debug | -d]
#                    [--help | -h]

require 'rubygems'
require 'httparty'
require 'getoptlong'

#Nagios return messages, these class methods exit with the appropriate exit code and message
class Nagios
  # return nagios status of OK, exit code 0
  def self.ok msg=""
    puts "OK: #{msg}"
    exit 0
  end
  # return nagios status of WARNING, exit code 1
  def self.warning msg=""
    puts "WARNING: #{msg}"
    exit 1
  end
  # return nagios status of CRITICAL, exit code 2
  def self.critical msg=""
    puts "CRITICAL: #{msg}"
    exit 2
  end
  # return nagios status of UNKOWN, exit code 3
  def self.unknown msg=""
    puts "UNKNOWN: #{msg}"
    exit 3
  end
  # format perfdata using following format:
  # 'label'=value[UOM];[warn];[crit];[min];[max]
  # this should be appended to status msg of ok, warn, or crit
  def self.perf_data label, metric_value, warn, crit
    "#{label}=#{metric_value};#{warn};#{crit};;"
  end
end

# NewRelicApi class wraps the NewRelic API and parses results
class NewRelicApi
  include HTTParty
  base_uri 'rpm.newrelic.com'

  # set the api key to connect to NewRelic API,
  # see http://newrelic.com to get an api key
  def self.set_api_key api_key
    headers 'x-license-key' => api_key
  end

  # gets account data
  def self.get_account
    get("/accounts.xml")
  end

  # gets array of applications
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

#values may come in as float strings
def convert_to_test_value value, data_type
  if data_type == "float"
    test_value  = (value.to_f * 1000).to_i
  else
    test_value = value.to_i
  end
  test_value
end


# display command line options and explanation
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
@warning_threshold = @warning_threshold_formatted = 0
@critical_threshold = @critical_threshold_formatted = 0
@metric_data_type = "float"

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
      case arg.downcase
      when "response"
        @metric = "Response Time"
        @metric_data_type = "int"
      when "cpu" || "db"
        @metric = arg.upcase
      when "db"
        @metric = arg.upcase
      else
        @metric = arg.capitalize
      end
    when '--api-key'
      @api_key = arg
    when '--debug'
      require 'pp'
      puts "DEBUG FLAG SET"
      $debug = true
  end
end

if @metric_data_type == "int"
  @warning_threshold = @warning_threshold.to_i
  @critical_threshold = @critical_threshold.to_i
else
  @warning_threshold = @warning_threshold.to_f
  @critical_threshold = @critical_threshold.to_f
end

puts "warning_threshold = #{@warning_threshold}" if $debug
puts "critical_threshold = #{@critical_threshold}" if $debug
puts "application_name = #{@application_name}" if $debug
puts "metric = #{@metric}" if $debug
puts "api_key = #{@api_key}" if $debug

# Check to make sure neccessary flags are set
%w'application_name metric api_key'.each do |var|
  Nagios.unknown "Unspecified argument for #{var}" unless eval "defined? @#{var}"
end

# now that api_key has been given add it to NewRelicApi class
NewRelicApi.set_api_key @api_key

# Get metrics from NewRelic
results = NewRelicApi.get_metrics
if $debug
  puts "API Query results: "
  pp results
end

# Check if valid api_key
Nagios.unknown "Invalid NewRelic API key" if results.code == 500

# parse results into useable hash
parsed_data = NewRelicApi.parse_data(results)
if $debug
  puts "Parsed results: "
  pp parsed_data
end

# Check if valid application name
unless parsed_data.member? @application_name
  Nagios.unknown "Invalid application name for --app" 
end

# grab the metric being queried
formatted_metric_value = parsed_data[@application_name][@metric]['formatted_metric_value']
metric_value = parsed_data[@application_name][@metric]['metric_value']

label = "#{@application_name.split(" ").join("_")}_#{@metric.split(" ").join("_")}"

# format the perfdata
perf_data = Nagios.perf_data(
                          label,
                          metric_value, 
                          @warning_threshold, 
                          @critical_threshold) 
puts "Perf Data: #{perf_data}" if $debug

#handle variable datatypes in return data
warning_threshold_value = convert_to_test_value @warning_threshold, @metric_data_type
critical_threshold_value = convert_to_test_value @critical_threshold, @metric_data_type
metric_value = convert_to_test_value metric_value, @metric_data_type


# Crit if beyond critical threshold
if metric_value > critical_threshold_value
  Nagios.critical "#{formatted_metric_value} returned for #{@metric} exceeds threshold of #{@critical_threshold} #{perf_data}"
end

# Warn if beyond warning threshold
if metric_value > warning_threshold_value
  Nagios.warning "#{formatted_metric_value} returned for #{@metric} exceeds threshold of #{@warning_threshold} #{perf_data}"
end

# if not warn or critical, must be ok
Nagios.ok "#{metric_value} returned for #{@metric} | #{perf_data}"

# Should never get this far
Nagios.unknown "something failed"
