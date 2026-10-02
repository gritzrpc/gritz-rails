# frozen_string_literal: true

# protoc output does not follow Zeitwerk's naming rules.
$LOAD_PATH.unshift Rails.root.join("lib/protos").to_s
Dir[Rails.root.join("lib/protos/**/*_pb.rb")].each { |path| require path }
