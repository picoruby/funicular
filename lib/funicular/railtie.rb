# frozen_string_literal: true

require "rails/railtie"

module Funicular
  class Railtie < Rails::Railtie
    railtie_name :funicular

    initializer "funicular.middleware" do |app|
      if Rails.env.development?
        app.middleware.use Funicular::Middleware
      end
    end

    initializer "funicular.helpers" do
      ActiveSupport.on_load(:action_view) do
        require "funicular/helpers/picoruby_helper"
        include Funicular::Helpers::PicorubyHelper
      end
    end

    rake_tasks do
      load "tasks/funicular.rake"
    end
  end
end
