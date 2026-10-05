# frozen_string_literal: true

require "rails_helper"

# CYRA-542 — Il codice che i clienti incollano nel loro sito chiedeva «l'ultima versione» dello
# script, qualunque fosse: una URL jsDelivr senza versione risolve sempre sull'ultima pubblicata e la
# tiene in cache pochi giorni, quindi ogni pubblicazione arrivava da sé su tutti i siti già
# installati e nessuno poteva richiamarla. È la ragione per cui trackWebVitals nasce spento (emerso
# lavorando CYRA-534): una funzione che si propaga senza il consenso di chi ha il sito non si può
# disfare dopo.
#
# Il pin è sulla major (@0): dentro la stessa major le correzioni continuano ad arrivare da sole, un
# cambiamento che rompe no. Chi ha già incollato la URL nuda resta com'è — il rischio smette di
# crescere, non sparisce.
#
# Questo spec sta fuori dalle view di proposito: la regola non è «quelle due righe sono giuste oggi»,
# è «nessun punto del prodotto può mostrare la URL nuda domani». Una guida nuova, un testo tradotto o
# una pagina del sito la reintrodurrebbero in silenzio, e il silenzio è esattamente il modo in cui è
# arrivata la prima volta.
RSpec.describe "Snippet di installazione — versione dichiarata (CYRA-542)" do
  # Le cartelle che finiscono davanti a un cliente: view, componenti, testi tradotti, pagine statiche,
  # documentazione. `spec/` è escluso apposta — è qui che la URL nuda va nominata per poterla vietare.
  SNIPPET_SCAN_GLOB = "{app,config,docs,lib,public}/**/*.{erb,rb,yml,yaml,md,html,js,json,txt}"

  # Cattura la versione se c'è: `@bussolabs/closeyourit-js@0/dist/…` → "@0"; senza versione è nil.
  SNIPPET_URL = %r{cdn\.jsdelivr\.net/npm/@bussolabs/closeyourit-js(?<pin>@[\w.\-]+)?/}

  # I due punti che mostrano il codice da incollare. Sono elencati perché un guard che non trova
  # niente passa lo stesso: se qualcuno sposta o rinomina lo snippet, la regola deve rumoreggiare
  # invece di diventare una prova a vuoto.
  PUNTI_ATTESI = [
    "app/views/member/guides/analytics.html.erb",
    "app/views/member/guides/replays.html.erb",
    "app/views/member/monitoring/analytics/show.html.erb"
  ].freeze

  # CYRA-648 — il codice del replay carica una SECONDA libreria dalla stessa CDN (la registrazione
  # vera e propria, che il kit non porta con sé). Vale la stessa regola: senza versione nell'indirizzo
  # ogni pubblicazione di quella libreria arriva da sola su tutti i siti già installati.
  RRWEB_URL = %r{cdn\.jsdelivr\.net/npm/rrweb(?<pin>@[\w.\-]+)?/(?<path>[\w./\-]+)}

  # Ogni citazione della URL nel prodotto, con il file da cui viene e la versione che dichiara. Il
  # CHANGELOG è nell'elenco perché le sue voci si leggono DENTRO l'app, non solo su GitHub: una voce
  # che riportasse il codice da incollare sarebbe un punto del prodotto a tutti gli effetti.
  def citazioni
    (Rails.root.glob(SNIPPET_SCAN_GLOB) + [ Rails.root.join("CHANGELOG.md") ]).flat_map do |path|
      contenuto = path.read(mode: "r:UTF-8", invalid: :replace, undef: :replace)
      next [] unless contenuto.include?("closeyourit-js")

      contenuto.to_enum(:scan, SNIPPET_URL).map do
        { file: path.relative_path_from(Rails.root).to_s, pin: Regexp.last_match[:pin] }
      end
    end
  end

  it "nessun punto del prodotto mostra l'indirizzo dello script senza versione" do
    nude = citazioni.reject { |c| c[:pin] }

    expect(nude.map { |c| c[:file] }).to be_empty,
      "l'indirizzo senza versione si aggiorna da solo su tutti i siti installati: #{nude.map { |c| c[:file] }.uniq.join(', ')}"
  end

  it "i punti che mostrano il codice da incollare sono ancora quelli attesi" do
    expect(citazioni.map { |c| c[:file] }.uniq).to include(*PUNTI_ATTESI)
  end

  it "tutti i punti dichiarano la stessa versione major" do
    versioni = citazioni.map { |c| c[:pin] }.compact.uniq

    expect(versioni).to eq([ "@0" ])
  end

  it "anche la libreria di registrazione delle sessioni è chiesta a una versione dichiarata" do
    nude = citazioni_rrweb.reject { |c| c[:pin] }

    expect(nude.map { |c| c[:file] }).to be_empty,
      "l'indirizzo senza versione si aggiorna da solo su tutti i siti installati: #{nude.map { |c| c[:file] }.uniq.join(', ')}"
  end

  it "il codice da incollare per le registrazioni carica quella libreria" do
    expect(citazioni_rrweb.map { |c| c[:file] }.uniq).to include("app/views/member/guides/replays.html.erb")
  end

  # CYRA-648 — `dist/rrweb.umd.min.cjs` e `umd/rrweb.min.js` sono lo stesso identico file, ma il
  # primo viaggia con `content-type: application/node` e `x-content-type-options: nosniff`: il
  # browser si rifiuta di eseguirlo, `window.rrweb` non esiste e la registrazione non parte — in
  # silenzio, che è esattamente il guasto che questa guida esiste per chiudere.
  it "la libreria è chiesta all'indirizzo che il browser accetta di eseguire" do
    respinti = citazioni_rrweb.select { |c| c[:path].end_with?(".cjs") }

    expect(respinti.map { |c| c[:file] }).to be_empty,
      "servito come application/node con nosniff, il browser non lo esegue: #{respinti.map { |c| c[:file] }.uniq.join(', ')}"
  end

  def citazioni_rrweb
    (Rails.root.glob(SNIPPET_SCAN_GLOB) + [ Rails.root.join("CHANGELOG.md") ]).flat_map do |path|
      contenuto = path.read(mode: "r:UTF-8", invalid: :replace, undef: :replace)
      next [] unless contenuto.include?("jsdelivr")

      contenuto.to_enum(:scan, RRWEB_URL).map do
        { file: path.relative_path_from(Rails.root).to_s, pin: Regexp.last_match[:pin],
          path: Regexp.last_match[:path] }
      end
    end
  end
end
