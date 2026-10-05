# frozen_string_literal: true

class AddTraceIdToErrorsEvents < ActiveRecord::Migration[8.1]
  def change
    # trace_id top-level Sentry: correlazione log↔errori della stessa richiesta (specchio di
    # logs_entries, che già lo estrae e indicizza con lo stesso indice composito).
    add_column :errors_events, :trace_id, :string
    add_index :errors_events, %i[project_id trace_id]
  end
end
