# frozen_string_literal: true

class AllowUnknownAgentLimitReservationCost < ActiveRecord::Migration[8.1]
  def up
    change_column_default :agents_limit_reservations, :estimated_cost, from: 0, to: nil
    change_column_null :agents_limit_reservations, :estimated_cost, true
    remove_check_constraint :agents_limit_reservations, name: "agents_limit_reservation_cost_nonnegative"
    add_check_constraint :agents_limit_reservations,
                         "estimated_cost IS NULL OR estimated_cost >= 0",
                         name: "agents_limit_reservation_cost_nonnegative"
  end

  def down
    remove_check_constraint :agents_limit_reservations, name: "agents_limit_reservation_cost_nonnegative"
    change_column_null :agents_limit_reservations, :estimated_cost, false, 0
    change_column_default :agents_limit_reservations, :estimated_cost, from: nil, to: 0
    add_check_constraint :agents_limit_reservations,
                         "estimated_cost >= 0",
                         name: "agents_limit_reservation_cost_nonnegative"
  end
end
