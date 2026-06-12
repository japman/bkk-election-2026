class ResultRevision < ApplicationRecord
  belongs_to :recordable, polymorphic: true

  validates :source, inclusion: { in: %w[api admin] }
end
