# Licensed to Elasticsearch B.V. under one or more contributor
# license agreements. See the NOTICE file distributed with
# this work for additional information regarding copyright
# ownership. Elasticsearch B.V. licenses this file to you under
# the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

require_relative '../framework/fixture'
require_relative '../framework/settings'
require_relative '../services/logstash_service'
require_relative '../framework/helpers'
require "logstash/devutils/rspec/spec_helper"
require "socket"
require "json"
require "logstash/util"

describe "Test Logstash service when config reload is enabled" do
  before(:all) {
    @fixture = Fixture.new(__FILE__)
  }

  after(:all) {
    @fixture.teardown
  }
  
  let(:timeout_seconds) { 5 }
  let(:initial_port) { random_port }
  let(:reload_port) { random_port }
  let(:retry_attempts) { 60 }
  let(:output_file1) { Stud::Temporary.file.path }
  let(:output_file2) { Stud::Temporary.file.path }
  let(:sample_data) { '74.125.176.147 - - [11/Sep/2014:21:50:37 +0000] "GET /?flav=rss20 HTTP/1.1" 200 29941 "-" "FeedBurner/1.0 (http://www.FeedBurner.com)"' }
  
  let(:initial_config_file) { config_to_temp_file(@fixture.config("initial", { :port => initial_port, :file => output_file1 })) }
  let(:reload_config_file) { config_to_temp_file(@fixture.config("reload", { :port => reload_port, :file => output_file2 })) }

  it "can reload when changes are made to TCP port and grok pattern" do
    logstash_service = @fixture.get_service("logstash")
    logstash_service.spawn_logstash("-f", "#{initial_config_file}", "--config.reload.automatic", "true")
    logstash_service.wait_for_logstash
    wait_for_port(initial_port, retry_attempts)
    
    # try sending events with this
    send_data(initial_port, sample_data)
    Stud.try(retry_attempts.times, RSpec::Expectations::ExpectationNotMetError) do
      expect(IO.read(output_file1).gsub("\n", "")).to eq(sample_data)
    end
    
    # check metrics
    result = logstash_service.monitoring_api.event_stats
    expect(result["in"]).to eq(1)
    expect(result["out"]).to eq(1)
    
    # do a reload
    logstash_service.reload_config(initial_config_file, reload_config_file)

    logstash_service.wait_for_logstash
    wait_for_port(reload_port, retry_attempts)
    
    # make sure old socket is closed
    expect(is_port_open?(initial_port)).to be false
    
    send_data(reload_port, sample_data)
    Stud.try(retry_attempts.times, RSpec::Expectations::ExpectationNotMetError) do
      expect(LogStash::Util.blank?(IO.read(output_file2))).to be false
    end
    
    # check instance metrics. It should not be reset
    instance_event_stats = logstash_service.monitoring_api.event_stats
    expect(instance_event_stats["in"]).to eq(2)
    expect(instance_event_stats["out"]).to eq(2)

    # check pipeline metrics. It should be reset
    pipeline_event_stats = logstash_service.monitoring_api.pipeline_stats("main")["events"]
    expect(pipeline_event_stats["in"]).to eq(1)
    expect(pipeline_event_stats["out"]).to eq(1)
    
    # check reload stats
    pipeline_reload_stats = logstash_service.monitoring_api.pipeline_stats("main")["reloads"]
    instance_reload_stats = logstash_service.monitoring_api.node_stats["reloads"]
    expect(pipeline_reload_stats["successes"]).to eq(1)
    expect(pipeline_reload_stats["failures"]).to eq(0)
    expect(LogStash::Util.blank?(pipeline_reload_stats["last_success_timestamp"])).to be false
    expect(pipeline_reload_stats["last_error"]).to eq(nil)
    
    expect(instance_reload_stats["successes"]).to eq(1)
    expect(instance_reload_stats["failures"]).to eq(0)
    # parse the results and validate
    re = JSON.parse(IO.read(output_file2))
    expect(re["clientip"]).to eq("74.125.176.147")
    expect(re["response"]).to eq(200)
  end
end
