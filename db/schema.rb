# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_12_070354) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "candidates", force: :cascade do |t|
    t.string "color", default: "#0E7A3D", null: false
    t.datetime "created_at", null: false
    t.bigint "election_id", null: false
    t.string "name", null: false
    t.integer "number", null: false
    t.string "party"
    t.string "photo_url"
    t.datetime "updated_at", null: false
    t.index ["election_id", "number"], name: "index_candidates_on_election_id_and_number", unique: true
    t.index ["election_id"], name: "index_candidates_on_election_id"
  end

  create_table "elections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "data_mode", default: "api", null: false
    t.date "election_date", null: false
    t.string "name", null: false
    t.string "status", default: "scheduled", null: false
    t.datetime "updated_at", null: false
  end

  create_table "zones", force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.bigint "election_id", null: false
    t.integer "grid_col", null: false
    t.integer "grid_row", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["election_id", "code"], name: "index_zones_on_election_id_and_code", unique: true
    t.index ["election_id"], name: "index_zones_on_election_id"
  end

  add_foreign_key "candidates", "elections"
  add_foreign_key "zones", "elections"
end
