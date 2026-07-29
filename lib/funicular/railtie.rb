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

    initializer "funicular.epoch" do |app|
      # Every response carries X-Funicular-Epoch (docs decision 13):
      # the controller concern rotates the epoch, the middleware writes
      # the header. The middleware sits ABOVE the exception renderer so
      # even a 500 page carries it -- a header-less error response
      # would terminal the client over a mere server error.
      require "funicular/epoch_header"
      if defined?(ActionDispatch::ShowExceptions)
        app.middleware.insert_before ActionDispatch::ShowExceptions,
                                     Funicular::EpochHeader
      else
        app.middleware.use Funicular::EpochHeader
      end
      # :action_controller fires for both Base and API.
      ActiveSupport.on_load(:action_controller) do
        require "funicular/epoch_stamping"
        include Funicular::EpochStamping
      end
    end

    rake_tasks do
      load "tasks/funicular.rake"
    end
  end
end
