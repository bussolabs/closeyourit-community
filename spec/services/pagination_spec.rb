# frozen_string_literal: true

require "rails_helper"

RSpec.describe Pagination do
  def scope = Accounts::Account.order(:created_at)

  describe ".call" do
    context "lista vuota" do
      it "pagina 1, nessun record, una sola pagina, nessun controllo" do
        r = described_class.call(scope, page: 1, per: 25)

        expect(r.total).to eq(0)
        expect(r.records).to eq([])
        expect(r.total_pages).to eq(1)
        expect(r.from).to eq(0)
        expect(r.to).to eq(0)
        expect(r.prev?).to be false
        expect(r.next?).to be false
        expect(r.multiple_pages?).to be false
      end
    end

    context "una pagina piena (total == per)" do
      before { create_list(:account, 25) }

      it "una sola pagina, to == 25, next? false" do
        r = described_class.call(scope, page: 1, per: 25)

        expect(r.total).to eq(25)
        expect(r.total_pages).to eq(1)
        expect(r.records.size).to eq(25)
        expect(r.to).to eq(25)
        expect(r.next?).to be false
      end
    end

    context "una riga oltre la pagina (total == per + 1)" do
      before { create_list(:account, 26) }

      it "due pagine; pagina 1 piena con next?" do
        r = described_class.call(scope, page: 1, per: 25)

        expect(r.total_pages).to eq(2)
        expect(r.records.size).to eq(25)
        expect(r.from).to eq(1)
        expect(r.to).to eq(25)
        expect(r.prev?).to be false
        expect(r.next?).to be true
      end

      it "pagina 2 ha solo l'ultima riga, prev? true next? false" do
        r = described_class.call(scope, page: 2, per: 25)

        expect(r.records.size).to eq(1)
        expect(r.from).to eq(26)
        expect(r.to).to eq(26)
        expect(r.prev?).to be true
        expect(r.next?).to be false
      end
    end

    context "page fuori range" do
      before { create_list(:account, 5) }

      it "page 0 → clamp a 1" do
        expect(described_class.call(scope, page: 0, per: 25).page).to eq(1)
      end

      it "page oltre l'ultima → clamp all'ultima" do
        expect(described_class.call(scope, page: 999, per: 25).page).to eq(1)
      end

      it "page nil → 1" do
        expect(described_class.call(scope, page: nil, per: 25).page).to eq(1)
      end
    end

    context "per invalido" do
      before { create_list(:account, 3) }

      it "per 0 o nil → default TABLE_PER_PAGE" do
        expect(described_class.call(scope, page: 1, per: 0).per).to eq(App::Constants::TABLE_PER_PAGE)
        expect(described_class.call(scope, page: 1, per: nil).per).to eq(App::Constants::TABLE_PER_PAGE)
      end
    end

    context "scope raggruppato (count ritorna un Hash)" do
      before { create_list(:account, 3) }

      it "conta il numero di gruppi (chiavi dell'Hash), non l'Hash" do
        r = described_class.call(Accounts::Account.group(:id), page: 1, per: 25)
        expect(r.total).to eq(3)
      end
    end

    describe "#window (finestra numeri pagina, ±2)" do
      it "centrata sulla pagina corrente, clampata ai bordi" do
        create_list(:account, 130) # 6 pagine @ 25

        expect(described_class.call(scope, page: 3, per: 25).window).to eq([ 1, 2, 3, 4, 5 ])
        expect(described_class.call(scope, page: 1, per: 25).window).to eq([ 1, 2, 3 ])
        expect(described_class.call(scope, page: 6, per: 25).window).to eq([ 4, 5, 6 ])
      end

      it "una sola pagina → finestra vuota" do
        create_list(:account, 3)
        expect(described_class.call(scope, page: 1, per: 25).window).to eq([])
      end
    end
  end

  # Righe già in memoria (es. l'inventario database, che vive dentro un jsonb e non in colonne):
  # stesso Result, così Ui::PaginationComponent non distingue le due sorgenti.
  describe ".from_array" do
    let(:list) { (1..7).to_a }

    it "affetta la pagina richiesta e riporta i confini" do
      r = described_class.from_array(list, page: 2, per: 3)

      expect(r.records).to eq([ 4, 5, 6 ])
      expect(r.total).to eq(7)
      expect(r.total_pages).to eq(3)
      expect(r.from).to eq(4)
      expect(r.to).to eq(6)
      expect(r.prev?).to be true
      expect(r.next?).to be true
    end

    it "lista vuota → una pagina, nessun record, confini a zero" do
      r = described_class.from_array([], page: 1, per: 3)

      expect(r.records).to eq([])
      expect(r.total).to eq(0)
      expect(r.total_pages).to eq(1)
      expect(r.from).to eq(0)
      expect(r.to).to eq(0)
      expect(r.multiple_pages?).to be false
    end

    it "clampa page e per come .call" do
      expect(described_class.from_array(list, page: 0, per: 3).page).to eq(1)
      expect(described_class.from_array(list, page: 999, per: 3).page).to eq(3)
      expect(described_class.from_array(list, page: nil, per: 0).per).to eq(App::Constants::TABLE_PER_PAGE)
      expect(described_class.from_array(list, page: 1, per: 9_999).per).to eq(described_class::MAX_PER)
    end
  end

  # CYRA-794 — righe che il database ha GIÀ ordinato e tagliato: il totale si sa da un conteggio, la
  # pagina la taglia SQL. Serve dove la riga della lista è un aggregato (un GROUP BY), che con
  # `.from_array` costringerebbe a portare in memoria tutti i gruppi per mostrarne dieci.
  describe ".from_query" do
    it "chiede al blocco solo la fetta che compete alla pagina" do
      chiesto = nil
      r = described_class.from_query(total: 7, page: 2, per: 3) do |offset, limit|
        chiesto = [ offset, limit ]
        %w[d e f]
      end

      expect(chiesto).to eq([ 3, 3 ])
      expect(r.records).to eq(%w[d e f])
      expect(r.total).to eq(7)
      expect(r.total_pages).to eq(3)
      expect(r.from).to eq(4)
      expect(r.to).to eq(6)
    end

    it "clampa la pagina PRIMA di chiedere le righe: oltre l'ultima si legge l'ultima" do
      chiesto = nil
      r = described_class.from_query(total: 7, page: 999, per: 3) { |offset, limit| chiesto = [ offset, limit ] }

      expect(r.page).to eq(3)
      expect(chiesto).to eq([ 6, 3 ])
    end

    # Niente da mostrare: nemmeno la query per scoprirlo — il conteggio l'ha già detto.
    it "totale a zero → nessuna lettura, una pagina vuota" do
      letto = false
      r = described_class.from_query(total: 0, page: 1, per: 3) { letto = true }

      expect(letto).to be false
      expect(r.records).to eq([])
      expect(r.total_pages).to eq(1)
      expect(r.multiple_pages?).to be false
    end

    it "clampa per come gli altri costruttori" do
      expect(described_class.from_query(total: 7, page: 1, per: 0) { [] }.per).to eq(App::Constants::TABLE_PER_PAGE)
      expect(described_class.from_query(total: 7, page: 1, per: 9_999) { [] }.per).to eq(described_class::MAX_PER)
    end
  end
end
