# frozen_string_literal: true

require "rails_helper"

# rack-attack è disabilitato a livello suite (spec/support/rack_attack.rb): qui lo riabilitiamo
# per verificare la blocklist scanner. La blocklist è pura (nessun cache store necessario).
RSpec.describe "Rack::Attack scanner blocklist", type: :request do
  around do |ex|
    Rack::Attack.enabled = true
    ex.run
  ensure
    Rack::Attack.enabled = false
  end

  describe "sonde scanner bloccate con 404 silenzioso" do
    %w[
      /wp
      /wp-login.php
      /wp-admin/
      /wp-config.php
      /wordpress
      /xmlrpc.php
      /phpmyadmin/
      /.git/config
      /admin.php
      /x.php
      /vendor/phpunit/phpunit.php
    ].each do |path|
      it "blocca #{path}" do
        get path

        expect(response).to have_http_status(:not_found)
        expect(response.body).to eq("Not Found")
      end
    end
  end

  # Path coperti dalla blocklist SENSITIVE_PATHS (block/sensitive-file-probe). /config/master.key è
  # nuovo nella lista canonica e NON intercettato dallo scanner-probe: verifica davvero l'estensione.
  describe "sonde file sensibili bloccate con 404 silenzioso" do
    %w[
      /.env
      /config/master.key
    ].each do |path|
      it "blocca #{path}" do
        get path

        expect(response).to have_http_status(:not_found)
        expect(response.body).to eq("Not Found")
      end
    end
  end

  describe "path legittimi non bloccati" do
    it "lascia passare /up (health check)" do
      get "/up"

      expect(response).to have_http_status(:ok)
    end
  end

  # CYRA-176. Le URL dei blob portano il NOME DEL FILE come ultimo segmento di path
  # (/rails/active_storage/blobs/redirect/:signed_id/:filename). Senza esenzione, un allegato
  # legittimo chiamato deploy.cgi o install.php verrebbe intercettato dalla blocklist scanner e
  # risponderebbe 404 silenzioso — con una diagnosi tutt'altro che ovvia. Rails QUESTI path li serve
  # davvero, quindi il rationale "l'app è Rails, non esistono mai" non si applica.
  describe "rotte ActiveStorage esentate dalle blocklist di estensione" do
    %w[
      /rails/active_storage/blobs/redirect/abc123/install.php
      /rails/active_storage/blobs/redirect/abc123/deploy.cgi
      /rails/active_storage/blobs/proxy/abc123/legacy.asp
      /rails/active_storage/disk/abc123/script.jsp
    ].each do |path|
      it "non blocca #{path}" do
        get path

        # Il signed_id è finto: quello che conta è che NON sia il 404 muto di rack-attack
        # ("Not Found" come body), cioè che la richiesta arrivi fino a Rails.
        expect(response.body).not_to eq("Not Found")
      end
    end

    it "continua a bloccare le sonde .php fuori da ActiveStorage" do
      get "/uploads/shell.php"

      expect(response).to have_http_status(:not_found)
      expect(response.body).to eq("Not Found")
    end
  end

  # Il direct upload crea blob dai metadata DICHIARATI dal client, scavalcando lo sniff Marcel dei
  # service di upload — l'unico gate reale sul tipo di file. Non è usato da nessuna parte lato client.
  describe "direct upload di ActiveStorage" do
    # Entrambe le forme, non solo la canonica: Rails instrada anche quella con lo slash finale, e un
    # blocco per uguaglianza esatta si aggirerebbe con un carattere.
    %w[
      /rails/active_storage/direct_uploads
      /rails/active_storage/direct_uploads/
      /rails/active_storage/direct_uploads.json
      /rails/active_storage/direct_uploads.json/
    ].each do |path|
      it "è chiuso su #{path}" do
        post path

        expect(response).to have_http_status(:not_found)
        expect(response.body).to eq("Not Found")
      end
    end
  end
end
