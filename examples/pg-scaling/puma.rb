# frozen_string_literal: true

port ENV.fetch("PORT", 3000)
environment ENV.fetch("RACK_ENV", "production")
workers 2
threads 1, 5
