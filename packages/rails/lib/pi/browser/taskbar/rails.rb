# frozen_string_literal: true

require_relative "rails/version"

module Pi
  module Browser
    module Taskbar
      # Development-only Rails adapter package seam.
      module Rails
        def self.browser_asset_path
          File.join(__dir__, "rails", "assets", "pi_browser_taskbar.js")
        end
      end
    end
  end
end
