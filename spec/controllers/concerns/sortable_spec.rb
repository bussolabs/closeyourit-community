# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sortable do
  let(:harness) do
    Class.new do
      include Sortable
      public :sorted, :sorted_rows, :current_sort
      attr_reader :params

      def initialize(params)
        @params = ActionController::Parameters.new(params)
      end
    end
  end

  def sorted(scope, params, **kwargs)
    harness.new(params).sorted(scope, **kwargs)
  end

  describe "#sorted" do
    let(:columns) { { "name" => "LOWER(accounts.name)", "created" => :created_at }.freeze }

    it "param assente → ordine di default dello scope invariato" do
      scope = Accounts::Account.order(:email)
      expect(sorted(scope, {}, columns: columns).to_sql).to eq(scope.to_sql)
    end

    it "chiave fuori whitelist → ordine di default, il param non entra nel SQL" do
      scope = Accounts::Account.order(:email)
      out = sorted(scope, { sort: "evil; DROP TABLE accounts" }, columns: columns)

      expect(out.to_sql).to eq(scope.to_sql)
      expect(out.to_sql).not_to include("DROP")
    end

    context "con record reali" do
      let!(:zulu)  { create(:account, name: "Zulu") }
      let!(:alpha) { create(:account, name: "alpha") } # minuscola: pinna il LOWER()
      let!(:beta)  { create(:account, name: "Beta") }

      let(:scope) { Accounts::Account.where(id: [ zulu, alpha, beta ].map(&:id)) }

      it "espressione String ascendente (LOWER → case-insensitive)" do
        out = sorted(scope, { sort: "name" }, columns: columns)
        expect(out.map(&:name)).to eq(%w[alpha Beta Zulu])
      end

      it "prefisso '-' → discendente" do
        out = sorted(scope, { sort: "-name" }, columns: columns)
        expect(out.map(&:name)).to eq(%w[Zulu Beta alpha])
      end
    end

    it "spec Symbol → colonna qualificata col nome tabella, NULLS LAST e tiebreaker id" do
      sql = sorted(Accounts::Account.all, { sort: "created" }, columns: columns).to_sql

      expect(sql).to include('"accounts"."created_at" ASC NULLS LAST')
      expect(sql).to include('"accounts"."id" ASC')
    end

    it "sostituisce l'ordine di default (reorder), non lo accoda" do
      sql = sorted(Accounts::Account.order(:email), { sort: "created" }, columns: columns).to_sql
      expect(sql).not_to include("email")
    end

    context "spec Hash con joins su associazione nullable" do
      let(:org) { create(:organization) }
      let(:g_alpha) { create(:group, organization: org, name: "Alpha team") }
      let(:g_zeta)  { create(:group, organization: org, name: "Zeta team") }
      let!(:in_zeta)  { create(:project, organization: org, name: "In zeta", group: g_zeta) }
      let!(:in_alpha) { create(:project, organization: org, name: "In alpha", group: g_alpha) }
      let!(:orphan)   { create(:project, organization: org, name: "Orphan", group: nil) }

      let(:columns) { { "group" => { expr: "LOWER(projects_groups.name)", joins: :group } }.freeze }

      it "asc: ordina per la colonna associata, righe senza associazione in fondo (NULLS LAST)" do
        out = sorted(org.projects, { sort: "group" }, columns: columns)
        expect(out.map(&:id)).to eq([ in_alpha, in_zeta, orphan ].map(&:id))
      end

      it "desc: inverte, ma le righe senza associazione restano in fondo" do
        out = sorted(org.projects, { sort: "-group" }, columns: columns)
        expect(out.map(&:id)).to eq([ in_zeta, in_alpha, orphan ].map(&:id))
      end
    end
  end

  describe "#current_sort" do
    it "senza param → chiave vuota ascendente" do
      expect(harness.new({}).current_sort).to eq([ "", :asc ])
    end

    it "chiave nuda → asc, prefisso '-' → desc" do
      expect(harness.new(sort: "title").current_sort).to eq([ "title", :asc ])
      expect(harness.new(sort: "-title").current_sort).to eq([ "title", :desc ])
    end

    it "param custom per tabelle multiple sulla stessa pagina" do
      expect(harness.new(invitations_sort: "-email").current_sort(:invitations_sort)).to eq([ "email", :desc ])
    end
  end

  # CYRA-924 — the same contract for rows already in memory (small tables built in Ruby).
  describe "#sorted_rows" do
    let(:rows) { [ { name: "zulu", cpu: 3.0 }, { name: "Alpha", cpu: nil }, { name: "mike", cpu: 9.5 } ] }
    let(:columns) { { "name" => ->(row) { row[:name].downcase }, "cpu" => ->(row) { row[:cpu] } }.freeze }

    def names(params, param: :sort)
      harness.new(params).sorted_rows(rows, columns: columns, param: param).map { |row| row[:name] }
    end

    it "keeps the given order without a sort or with an unknown key" do
      expect(names({})).to eq(%w[zulu Alpha mike])
      expect(names({ sort: "evil" })).to eq(%w[zulu Alpha mike])
    end

    it "sorts ascending and descending" do
      expect(names({ sort: "name" })).to eq(%w[Alpha mike zulu])
      expect(names({ sort: "-name" })).to eq(%w[zulu mike Alpha])
    end

    it "keeps missing values last in both directions" do
      expect(names({ sort: "cpu" })).to eq(%w[zulu mike Alpha])
      expect(names({ sort: "-cpu" })).to eq(%w[mike zulu Alpha])
    end

    it "reads a custom param" do
      expect(names({ processes_sort: "-cpu" }, param: :processes_sort)).to eq(%w[mike zulu Alpha])
    end
  end
end
