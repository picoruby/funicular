# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Funicular
  module Generators
    class ChatGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end

      def create_rails_files
        migration_template "create_funicular_chat_messages.rb.tt",
                           "db/migrate/create_funicular_chat_messages.rb"
        template "funicular_chat_message.rb.tt",
                 "app/models/funicular_chat_message.rb"
        template "funicular_chat_controller.rb.tt",
                 "app/controllers/funicular_chat_controller.rb"
        template "funicular_chat_messages_controller.rb.tt",
                 "app/controllers/funicular_chat_messages_controller.rb"
        template "application_cable_connection.rb.tt",
                 "app/channels/application_cable/connection.rb" unless File.exist?(Rails.root.join("app", "channels", "application_cable", "connection.rb"))
        template "application_cable_channel.rb.tt",
                 "app/channels/application_cable/channel.rb" unless File.exist?(Rails.root.join("app", "channels", "application_cable", "channel.rb"))
        template "funicular_chat_channel.rb.tt",
                 "app/channels/funicular_chat_channel.rb"
        template "show.html.erb.tt",
                 "app/views/funicular_chat/show.html.erb"
        template "funicular_chat.css.tt",
                 "app/assets/stylesheets/funicular_chat.css"
      end

      def create_funicular_files
        template "funicular_chat_component.rb.tt",
                 "app/funicular/components/funicular_chat_component.rb"
        template "funicular_chat_component_picotest.rb.tt",
                 "test/funicular/client/funicular_chat_component_picotest.rb"

        @initializer_existed = File.exist?(Rails.root.join("app", "funicular", "initializer.rb"))
        if @initializer_existed
          say_status :skip, "app/funicular/initializer.rb already exists", :yellow
        else
          template "initializer.rb.tt", "app/funicular/initializer.rb"
        end
      end

      def add_routes
        routes_file = Rails.root.join("config", "routes.rb")
        if File.exist?(routes_file) && File.read(routes_file).include?('get "funicular_chat"')
          say_status :skip, "funicular_chat routes already exist", :yellow
          return
        end

        route <<~ROUTES
          get "funicular_chat", to: "funicular_chat#show"
          get "funicular_chat/messages", to: "funicular_chat_messages#index"
          post "funicular_chat/messages", to: "funicular_chat_messages#create"
        ROUTES
      end

      def add_picoruby_include_tag
        layout = Rails.root.join("app", "views", "layouts", "application.html.erb")
        return unless File.exist?(layout)

        content = File.read(layout)
        return if content.include?("picoruby_include_tag")

        if content.include?("<%= csrf_meta_tags %>")
          inject_into_file layout.to_s,
                           "    <%= picoruby_include_tag %>\n",
                           after: "    <%= csrf_meta_tags %>\n"
        else
          say_status :skip, "layout does not contain csrf_meta_tags; add <%= picoruby_include_tag %> manually", :yellow
        end
      end

      def print_next_steps
        say ""
        say "Funicular chat generated.", :green
        say ""
        say "Next steps:"
        say "  1. Run `bin/rails db:migrate`"
        say "  2. Run `bin/rails funicular:compile`"
        say "  3. Open `/funicular_chat` in two browser windows"
        say ""

        if @initializer_existed
          say "Add this route inside your existing Funicular.start block:"
          say "  router.get('/funicular_chat', to: FunicularChatComponent, as: 'funicular_chat')"
          say ""
        end
      end
    end
  end
end
