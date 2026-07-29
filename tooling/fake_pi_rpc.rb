#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

transcript_path = ARGV.fetch(0) { abort "usage: fake_pi_rpc.rb TRANSCRIPT" }
transcript = JSON.parse(File.read(transcript_path))

transcript.fetch("steps").each_with_index do |step, index|
  case step.fetch("direction")
  when "receive"
    line = $stdin.gets
    abort "step #{index + 1}: expected input" unless line

    actual = JSON.parse(line)
    expected = step.fetch("message")
    abort "step #{index + 1}: unexpected input" unless actual == expected
  when "send"
    $stdout.puts(JSON.generate(step.fetch("message")))
    $stdout.flush
  else
    abort "step #{index + 1}: unknown direction"
  end
end

abort "unexpected input after transcript" if $stdin.gets
