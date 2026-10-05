# frozen_string_literal: true

require_relative "runtime"
Certification::Runtime.boot!
require "solid_queue/cli"

SolidQueue::Cli.start([ "start", "--mode", "async", "--skip-recurring", "--config-file", File.expand_path("queue.yml", __dir__) ])
