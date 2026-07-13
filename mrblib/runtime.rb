module Funicular
  class Runtime
    attr_accessor :router

    def initialize(router = nil)
      @router = router
    end

    def routes
      router = @router
      if router
        router.route_helpers
      else
        EmptyRoutes
      end
    end
  end

  module EmptyRoutes
    def self.method_missing(name, *args)
      raise NoMethodError, "undefined route helper #{name}"
    end

    def self.respond_to_missing?(name, include_private = false)
      false
    end
  end
end
