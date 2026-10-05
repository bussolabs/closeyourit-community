# frozen_string_literal: true

# Postura di SERVING dei file caricati (CYRA-176). Le pagine KB accettano anche script
# (Knowledge::Attachment): sono archivi inerti, e nulla deve poterli far eseguire o renderizzare.
#
# Qui si governa lo strato "browser" della difesa. Gli altri strati stanno altrove e non dipendono da
# questo file: i blob vivono su S3 privato fuori da public/ (storage.yml + production.rb), l'immagine
# non contiene interpreti (Dockerfile), il tipo è sniffato sui byte reali da Marcel nei service di
# upload, e l'allowlist vieta svg/html/xml (App::Constants).
#
# PERCHÉ le liste sono LETTERALI e non Knowledge::Constants::SCRIPT_CONTENT_TYPES: le costanti
# dell'app non sono autoloadabili durante gli initializer (zeitwerk → `uninitialized constant App`), e
# la config va scritta QUI e non in un after_initialize — ActiveStorage travasa
# `config.active_storage.*` sugli attributi del modulo dentro il proprio after_initialize, che gira
# DOPO quelli dell'app (verificato: un after_initialize nostro veniva sovrascritto).
# La duplicazione con App::Constants è quindi obbligata, ed è vincolata da
# spec/config/active_storage_serving_spec.rb: se le due liste divergono, la suite fallisce.
Rails.application.configure do
  # Tipi riscritti a application/octet-stream quando serviti. ActiveStorage ne porta 9 di serie
  # (text/html, image/svg+xml, application/xml, xhtml, postscript, flash, mathml, cache-manifest...):
  # li ESTENDIAMO — non li sostituiamo — con i tipi script della KB. Un text/javascript o un
  # application/x-sh conserverebbero altrimenti il proprio Content-Type reale.
  # Difesa GLOBALE: vale su qualunque rotta blob e per qualunque chiamante, anche futuro, che non
  # passi dal controller di download degli allegati.
  config.active_storage.content_types_to_serve_as_binary =
    ActiveStorage::Engine.config.active_storage.content_types_to_serve_as_binary | %w[
      application/x-sh
      text/x-ruby
      text/x-python
      text/javascript
      application/json
      text/x-yaml
      application/sql
      text/x-diff
      text/x-php
      text/x-java-source
      text/x-csrc
      application/x-tar
      application/gzip
    ]

  # Tipi renderizzabili inline. È il default 8.1 dichiarato ESPLICITO (raster + PDF) più i video di
  # App::Constants::VIDEO_CONTENT_TYPES: il tag <video> del dettaglio ticket non riproduce un file
  # servito forced-download, e un video non è un vettore di script. Tutto il resto riceve Content-Disposition: attachment forzato da ActiveStorage
  # (ActiveStorage::Blob::Servable#forced_disposition_for_serving), anche se un chiamante chiede
  # disposition: :inline.
  #
  # È lo strato che copre la falla residua dello sniff: un FRAMMENTO html senza doctype
  # (`<img src=x onerror=...>`) non ha magic byte, Marcel lo classifica text/plain anche se il file si
  # chiama .html, e text/plain è in allowlist. Non essendo inline-renderizzabile, il browser lo scarica
  # invece di eseguirlo. Scriverlo a mano lo rende una scelta esplicita e non un default ereditato che
  # un upgrade di Rails potrebbe allargare sotto di noi.
  config.active_storage.content_types_allowed_inline = %w[
    image/webp
    image/avif
    image/png
    image/gif
    image/jpeg
    image/tiff
    image/bmp
    application/pdf
    video/mp4
    video/quicktime
    video/webm
    video/x-matroska
    video/x-msvideo
  ]
end
