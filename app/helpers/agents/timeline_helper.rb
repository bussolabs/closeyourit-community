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
      when :done then "relative h-3 w-3 rounded-full border-2 border-emerald-500 bg-emerald-500"
      when :current then "relative h-3 w-3 rounded-full border-2 border-indigo-600 dark:border-indigo-400 bg-white dark:bg-zinc-900"
      else "relative h-3 w-3 rounded-full border-2 border-stone-300 dark:border-zinc-700 bg-white dark:bg-zinc-900"
      end
    end

    # Etichetta del passaggio: quello in corso è l'unico che si fa notare.
    def agent_step_label_class(status)
      case status
      when :done then "text-[11px] text-gray-500 dark:text-zinc-400"
      when :current then "text-[11px] font-semibold text-zinc-900 dark:text-zinc-100"
      else "text-[11px] text-gray-400 dark:text-zinc-500"
      end
    end

    # The segment leading to a step: filled once the work has reached that step (CYRA-1032).
    def agent_step_connector_class(status)
      if status == :pending
        "absolute right-1/2 top-[5px] h-0.5 w-full bg-stone-200 dark:bg-zinc-700"
      else
        "absolute right-1/2 top-[5px] h-0.5 w-full bg-emerald-500"
      end
    end
  end
end
