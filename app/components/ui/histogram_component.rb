# frozen_string_literal: true

module Ui
  # Corpo del grafico "Occorrenze nel tempo" (istogramma a barre) condiviso dalle show di
  # error group e metric group. Puro layout, zero logica di dominio: colore barra, riga valore
  # del tooltip e finestra oraria arrivano già calcolati dai view-model (`error_chart_bars` /
  # `metric_chart_bars` + `chart_gridlines` / `chart_xticks` in Monitoring::ChartsHelper).
  #
  # Rende: gutter Y con le etichette valore allineate alle gridline · plot con gridline dietro
  # le barre · asse X con le etichette temporali · summary sr-only · un tooltip flottante
  # (Stimulus `monitoring--histogram`, position:fixed su hover della barra).
  #
  #   bars:            [{ height:Int(%), color_class:String, time_label:String, value_line:String,
  #                        href:String?, active:Bool, aria_label:String, unsampled:Bool, empty:Bool }]
  #   gridlines:       [{ value:Int|String, pct:Float }]  # value già formattato con l'unità, se serve
  #   xticks:          [{ label:String, pct:Float }]
  #   buckets_test_id: "error-buckets" | "duration-buckets" (hook system spec)
  #   summary:         testo sr-only (accessibilità: la riga barre è aria-hidden)
  #   empty_label:     frase da mostrare quando il periodo non ha niente da disegnare (default generico)
  #
  # Drill-down (CYRA-46): una barra con `href` diventa un link (<a>) cliccabile che filtra le
  # occorrenze al blocco temporale; `active` la evidenzia col ring. Quando ALMENO una barra è un
  # link, la riga barre NON è più aria-hidden (i link devono essere raggiungibili) e ogni barra-link
  # porta `aria_label`; le barre non interattive restano <span> decorativi (aria-hidden).
  #
  # Non misurato (CYRA-457): una barra con `unsampled: true` è un blocco senza campioni, reso come
  # fascia tratteggiata (bg-hatch) a piena altezza invece della barra minima — così un intervallo
  # non misurato non si legge come un valore ≈ 0. I chiamanti che non lo passano restano invariati.
  #
  # Periodo senza dati (CYRA-570): quando NESSUN blocco ha qualcosa (`empty`/`unsampled` su tutti, o
  # nemmeno un blocco) il grafico non si disegna affatto — lo dichiara a parole, a schermo. Una fila
  # di barrette tutte della stessa altezza minima si legge come «pochissimo traffico» invece che
  # «non è stato misurato niente», e su un errore già risolto non distingue «non è più successo» da
  # «il grafico non ha caricato»; per giunta il riquadro occupava un quarto di schermata per non dire
  # nulla, spingendo in basso il messaggio utile. Il chiamante che ha una frase di dominio la passa
  # con `empty_label`, altrimenti resta quella generica.
  class HistogramComponent < BaseComponent
    def initialize(bars:, gridlines: [], xticks: [], buckets_test_id: nil, summary: nil, empty_label: nil)
      @bars = Array(bars)
      @gridlines = Array(gridlines)
      @xticks = Array(xticks)
      @buckets_test_id = buckets_test_id
      @summary = summary
      @empty_label = empty_label
    end

    private

    # Il periodo non ha NIENTE da disegnare. Un chiamante che non marca i blocchi vuoti (nessuna
    # chiave `empty`/`unsampled`) non entra mai qui: il grafico resta quello di prima.
    def no_data? = @bars.blank? || @bars.all? { |bar| bar[:empty] || bar[:unsampled] }

    # Signed charts opt in; legacy bars keep their original geometry.
    def bar_style(bar)
      return "height: #{bar[:height]}%" unless bar.key?(:bottom)
      "height: max(1px, #{bar[:height]}%); position: relative; bottom: #{bar[:bottom]}%"
    end

    def empty_text = @empty_label.presence || t("shared.histogram.empty")

    # C'è almeno una barra cliccabile? Governa aria-hidden della riga barre.
    def interactive? = @bars.any? { |b| b[:href].present? }

    # CYRA-663 — su schermo stretto le barre cliccabili hanno bisogno di spazio per restare
    # toccabili, e il grafico scorre. La larghezza minima era una costante tarata su 56 barre:
    # con 30 imponeva uno scorrimento che non serviva a niente. Qui si deriva dal numero vero.
    # E' uno style inline e non una classe perche' Tailwind genera solo le classi che trova
    # scritte nel sorgente: una larghezza calcolata a runtime non esisterebbe nel foglio.
    MIN_BAR_WIDTH_PX = 27

    # La larghezza vale solo sotto md (classi in template): da tablet in su il grafico si stringe
    # invece di scorrere, anche con 48 barre su un portatile.
    def min_width_style
      return nil unless interactive?

      "--histogram-min-width: #{@bars.size * MIN_BAR_WIDTH_PX}px"
    end

    # Il gutter Y è largo quanto l'etichetta più lunga (in `ch` del suo font mono), mai meno di 2rem:
    # a larghezza fissa «95,4 MB» andava a capo e si sovrapponeva alla riga vicina.
    def gutter_style
      longest = @gridlines.map { |g| g[:value].to_s.length }.max.to_i
      "width: max(2rem, #{longest}ch)"
    end

    # Posizionamento orizzontale di un'etichetta X: agli estremi si ancora al bordo per non
    # sforare, altrimenti centrata sulla colonna.
    def xtick_style(pct)
      return [ "left: 0", nil ] if pct <= 0
      return [ "right: 0", nil ] if pct >= 100

      [ "left: #{pct}%", "-translate-x-1/2" ]
    end

    # Posizionamento verticale di un'etichetta Y, speculare a xtick_style: alla base si appoggia al
    # bordo inferiore del plot (centrata sborderebbe per metà sotto il grafico), altrimenti resta
    # centrata sulla propria gridline.
    def ytick_style(pct)
      return [ "bottom: 0", nil ] if pct <= 0
      return [ "top: 0", nil ] if pct >= 100

      [ "bottom: #{pct}%", "-translate-y-1/2" ]
    end
  end
end
