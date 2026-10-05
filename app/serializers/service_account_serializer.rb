# frozen_string_literal: true

# Service account (canale CLI). Identità dell'account; la restrizione env (org-scoped, dalla membership)
# e il conteggio token attivi sono aggiunti dal controller (dipendono dall'org del token). MAI
# password_digest né l'email sintetica.
class ServiceAccountSerializer < ApplicationSerializer
  attributes :id, :name, :handle, :created_at
end
