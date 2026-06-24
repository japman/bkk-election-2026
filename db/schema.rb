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

ActiveRecord::Schema[8.1].define(version: 2026_06_24_155833) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "candidates", force: :cascade do |t|
    t.string "color", default: "#0E7A3D", null: false
    t.datetime "created_at", null: false
    t.bigint "election_id", null: false
    t.string "external_id"
    t.string "name", null: false
    t.integer "number", null: false
    t.string "party"
    t.string "party_logo_url"
    t.string "photo_url"
    t.datetime "updated_at", null: false
    t.bigint "zone_id"
    t.index ["election_id", "number"], name: "idx_candidates_election_number_governor", unique: true, where: "(zone_id IS NULL)"
    t.index ["election_id", "zone_id", "number"], name: "idx_candidates_election_zone_number_council", unique: true, where: "(zone_id IS NOT NULL)"
    t.index ["election_id"], name: "index_candidates_on_election_id"
    t.index ["external_id"], name: "index_candidates_on_external_id", unique: true, where: "(external_id IS NOT NULL)"
    t.index ["zone_id"], name: "index_candidates_on_zone_id"
  end

  create_table "elections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "data_mode", default: "api", null: false
    t.date "election_date", null: false
    t.string "kind", default: "governor", null: false
    t.string "name", null: false
    t.string "status", default: "scheduled", null: false
    t.datetime "updated_at", null: false
  end

  create_table "result_revisions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "editor"
    t.jsonb "new_values", default: {}, null: false
    t.jsonb "old_values", default: {}, null: false
    t.bigint "recordable_id", null: false
    t.string "recordable_type", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_result_revisions_on_created_at"
    t.index ["recordable_type", "recordable_id"], name: "index_result_revisions_on_recordable"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "vote_results", force: :cascade do |t|
    t.bigint "candidate_id", null: false
    t.datetime "created_at", null: false
    t.string "source", default: "api", null: false
    t.datetime "updated_at", null: false
    t.integer "votes", default: 0, null: false
    t.bigint "zone_id", null: false
    t.index ["candidate_id"], name: "index_vote_results_on_candidate_id"
    t.index ["zone_id", "candidate_id"], name: "index_vote_results_on_zone_id_and_candidate_id", unique: true
    t.index ["zone_id"], name: "index_vote_results_on_zone_id"
  end

  create_table "zone_stats", force: :cascade do |t|
    t.integer "bad_ballots", default: 0, null: false
    t.decimal "counted_percent", precision: 5, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.integer "eligible_voters", default: 0, null: false
    t.integer "no_vote", default: 0, null: false
    t.string "source", default: "api", null: false
    t.integer "turnout", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "zone_id", null: false
    t.index ["zone_id"], name: "index_zone_stats_on_zone_id", unique: true
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
  add_foreign_key "candidates", "zones"
  add_foreign_key "sessions", "users"
  add_foreign_key "vote_results", "candidates"
  add_foreign_key "vote_results", "zones"
  add_foreign_key "zone_stats", "zones"
  add_foreign_key "zones", "elections"
end
