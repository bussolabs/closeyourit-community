# frozen_string_literal: true

require "rails_helper"

# I valori dei segreti entrano nei controller del vault (progetto, condiviso, personale — canale web e
# CLI) sotto tre soli nomi di parametro: `value` (secret singolo), `values` (matrice nome×ambiente del
# form web) e `variables` (import in blocco da riga di comando). La lista `filter_parameters` fa match
# per SOTTOSTRINGA sul nome: finché nessuna voce compare in questi tre nomi, il valore in chiaro finisce
# nei log di Rails a ogni salvataggio, e chi legge i log raccoglie le credenziali man mano che vengono
# ruotate — senza alcun permesso sul vault e senza comparire in nessun audit (CYRA-203).
#
# Questa spec costruisce il filtro ESATTAMENTE come fa il logging di Rails (dall'array di config) e
# blocca la regressione su tutti e tre i nomi.
RSpec.describe "Filtro dei parametri sensibili nei log" do
  subject(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  it "maschera il valore singolo `value` (create web e CLI dei tre vault)" do
    expect(filter.filter("value" => "s3cr3t")).to eq("value" => "[FILTERED]")
  end

  it "maschera la matrice `values` (riga della matrice nome×ambiente del canale web)" do
    filtered = filter.filter("values" => { "42" => "s3cr3t", "43" => "altro-s3cr3t" })

    expect(filtered["values"]).to eq("[FILTERED]")
    expect(filtered.inspect).not_to include("s3cr3t")
  end

  it "maschera l'import in blocco `variables`: nemmeno uno dei venti valori resta in chiaro" do
    entries = Array.new(20) { |i| { "name" => "VAR_#{i}", "value" => "s3cr3t-#{i}" } }
    filtered = filter.filter("variables" => entries)

    expect(filtered["variables"]).to eq("[FILTERED]")
    expect(filtered.inspect).not_to include("s3cr3t")
  end

  it "installs ingest privacy before Rails logs a request" do
    stack = Rails.application.middleware.map(&:klass)
    expect(stack.index(Ingest::PrivateRequest)).to be < stack.index(Rails::Rack::Logger)
  end

  %w[logs metrics pageviews replays].each do |channel|
    it "filters the entire #{channel} body and query without changing parsed input" do
      body = { "arbitrary" => { "nested" => "private-1210@example.test" } }
      env = Rack::MockRequest.env_for("/api/v1/projects/project-id/#{channel}?arbitrary=private-query",
        method: "POST", input: body.to_json, "CONTENT_TYPE" => "application/json")
      app = lambda do |request_env|
        request = ActionDispatch::Request.new(request_env)
        expect(request.filtered_parameters).to eq("payload" => "[FILTERED]")
        expect(request.filtered_path).not_to include("private-query")
        expect(request.request_parameters).to eq(body)
        [ 200, {}, [] ]
      end
      Ingest::PrivateRequest.new(app).call(env)
    end
  end

  it "also hides field names and bare query strings on the formatted routes" do
    body = { "private-1210@example.test" => "private-value" }
    env = Rack::MockRequest.env_for("/api/v1/projects/project-id/logs.json?private-query",
      method: "POST", input: body.to_json, "CONTENT_TYPE" => "application/json")
    app = lambda do |request_env|
      request = ActionDispatch::Request.new(request_env)
      expect(request.filtered_parameters).to eq("payload" => "[FILTERED]")
      expect(request.filtered_path).to eq("/api/v1/projects/project-id/logs.json?[FILTERED]")
      expect(request.request_parameters).to eq(body)
      [ 200, {}, [] ]
    end
    Ingest::PrivateRequest.new(app).call(env)
  end

  it "leaves parameter filtering on other endpoints unchanged" do
    filters = Rails.application.config.filter_parameters
    env = Rack::MockRequest.env_for("/api/v1/projects/project-id/events")
    env["action_dispatch.parameter_filter"] = filters
    app = ->(request_env) { expect(request_env["action_dispatch.parameter_filter"]).to equal(filters) }
    Ingest::PrivateRequest.new(app).call(env)
  end
end
