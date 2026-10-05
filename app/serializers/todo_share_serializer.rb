# frozen_string_literal: true

# Destinatario di una condivisione (un Account membro dell'org) per l'endpoint sharing della CLI.
class TodoShareSerializer < ApplicationSerializer
  attributes :id, :name, :handle
end
