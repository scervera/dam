module Dam
  class Engine < ::Rails::Engine
    isolate_namespace Dam

    # The engine ships no migrations to run in place: new apps get the tables from
    # `bin/rails generate dam:install`. Apps that already have them keep their own.
    config.paths["db/migrate"] = []
  end
end
