# frozen_string_literal: true

module Agents
  # CYRA-183 — il PERCORSO di una lavorazione: pallini, etichette e segmenti dei passaggi. Classi
  # LETTERALI, perché Tailwind non vede le stringhe composte a runtime e non genererebbe le utility.
  # I passaggi e il loro stato arrivano da Agents::RunTimeline, qui c'è solo la loro resa (CYRA-742).
  module TimelineHelper
    # Pallino del passaggio nella timeline (CYRA-183). Classi LETTERALI: Tailwind non vede le stringhe
    # composte a runtime e non genererebbe le utility.
    def agent_step_dot_class(status)
      case status
      when :done then "h-2 w-2 rounded-full bg-emerald-500"
      when :current then "h-2.5 w-2.5 rounded-full bg-indigo-600 ring-2 ring-indigo-200 dark:ring-indigo-500/40"
      else "h-2 w-2 rounded-full border border-stone-300 dark:border-zinc-700 bg-white dark:bg-zinc-900"
      end
    end

    # Etichetta del passaggio: quello in corso è l'unico che si fa notare.
    def agent_step_label_class(status)
      case status
      when :done then "text-[10.5px] text-gray-500 dark:text-zinc-400"
      when :current then "text-[10.5px] font-semibold text-indigo-700 dark:text-indigo-300"
      else "text-[10.5px] text-gray-400 dark:text-zinc-500"
      end
    end

    # Segmento tra due pallini: pieno fino a dove il lavoro è arrivato.
    def agent_step_connector_class(status)
      status == :done ? "h-px flex-1 bg-emerald-300" : "h-px flex-1 bg-stone-200 dark:bg-zinc-700"
    end
  end
end
