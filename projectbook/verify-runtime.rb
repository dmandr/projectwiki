# Fail the build if source dependencies diverge from the pinned runtime image.
require 'rubygems'
spec = Gem::Specification.load('gollum.gemspec')
missing = spec.runtime_dependencies.reject { |dependency| dependency.matching_specs.any? }
abort "Pinned runtime does not satisfy: #{missing.join(', ')}" unless missing.empty?
puts "Pinned runtime satisfies #{spec.runtime_dependencies.length} direct runtime dependencies."

# A production gem must retain the hidden asset lookup table as well as bundles.
manifests = spec.files.grep(%r{lib/gollum/public/assets/\.sprockets-manifest-.*\.json$})
abort 'Production Sprockets manifest is missing from the gem file list.' if manifests.empty?
require 'json'
manifests.each do |manifest|
  JSON.parse(File.read(manifest)).fetch('assets').each_value do |asset|
    abort "Missing bundled asset: #{asset}" unless File.file?(File.join(File.dirname(manifest), asset))
  end
end
puts 'Production asset manifest and referenced bundles are present.'
