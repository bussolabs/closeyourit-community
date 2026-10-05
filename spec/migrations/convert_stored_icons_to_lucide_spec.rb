# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261001200000_convert_stored_icons_to_lucide")

RSpec.describe ConvertStoredIconsToLucide do
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.public_send(direction) }
  end

  # Raw SQL: the model normalizes a Font Awesome name before it reaches the row, even on update_column.
  def store_icon(record, name)
    connection = record.class.connection
    connection.execute("UPDATE #{record.class.table_name} SET icon = #{connection.quote(name)} " \
                       "WHERE id = #{connection.quote(record.id)}")
  end

  def stored_icon(record)
    record.class.where(id: record.id).pick(Arel.sql("icon"))
  end

  it "turns the Font Awesome names stored on projects, groups and uptime groups into Lucide names" do
    project = create(:project)
    group = create(:group)
    uptime_group = create(:uptime_group)
    store_icon(project, "gauge-high")
    store_icon(group, "robot")
    store_icon(uptime_group, "tower-broadcast")

    migrate(:up)

    expect([ project, group, uptime_group ].map { stored_icon(it) }).to eq(%w[gauge bot radio-tower])
  end

  # Font Awesome "box" is a carton (Lucide "package") and "cube" is Lucide "box": no chaining.
  it "moves box to package and cube to box in the same pass" do
    carton = create(:project)
    cube = create(:project)
    store_icon(carton, "box")
    store_icon(cube, "cube")

    migrate(:up)

    expect([ stored_icon(carton), stored_icon(cube) ]).to eq(%w[package box])
  end

  it "leaves names that are the same in both sets, and empty icons, as they are" do
    project = create(:project)
    other = create(:project)
    store_icon(project, "rocket")
    store_icon(other, nil)

    migrate(:up)

    expect(stored_icon(project)).to eq("rocket")
    expect(stored_icon(other)).to be_nil
  end

  it "gives back the Font Awesome names on rollback" do
    project = create(:project)
    store_icon(project, "gauge-high")

    migrate(:up)
    migrate(:down)

    expect(stored_icon(project)).to eq("gauge-high")
  end
end
