# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative 'sketchup_fakes'
require_relative '../../src/dcc_mcp_sketchup/sketchup_plugin/commands'

# Contract tests for the bounded Ruby command map.
#
# These run against tests/ruby/sketchup_fakes.rb, an in-memory stub of the
# SketchUp API. That makes them contract evidence, not host evidence: they prove
# the command layer honours its contract (parameter validation, one undo
# operation per mutation, and a post-write read-back that disagrees loudly), not
# that a real SketchUp executed the commands. See compat_matrix.json, which
# records that bound explicitly.
class CommandsTest < Minitest::Test
  def setup
    FakeIds.reset!
    Sketchup.active_model = FakeModel.new
    @commands = DccMcp::SketchupAdapter::Commands.new
  end

  def model
    Sketchup.active_model
  end

  def box_params(overrides = {})
    {
      'width' => 2.0, 'depth' => 1.0, 'height' => 0.5,
      'unit' => 'meters', 'name' => 'RubySmoke'
    }.merge(overrides)
  end

  def with_project(directory)
    previous = ENV['DCC_MCP_SKETCHUP_PROJECT_FOLDER']
    ENV['DCC_MCP_SKETCHUP_PROJECT_FOLDER'] = directory
    yield
  ensure
    if previous.nil?
      ENV.delete('DCC_MCP_SKETCHUP_PROJECT_FOLDER')
    else
      ENV['DCC_MCP_SKETCHUP_PROJECT_FOLDER'] = previous
    end
  end

  def with_approval
    previous = ENV['DCC_MCP_SKETCHUP_OWNER_APPROVAL']
    ENV['DCC_MCP_SKETCHUP_OWNER_APPROVAL'] = '1'
    yield
  ensure
    if previous.nil?
      ENV.delete('DCC_MCP_SKETCHUP_OWNER_APPROVAL')
    else
      ENV['DCC_MCP_SKETCHUP_OWNER_APPROVAL'] = previous
    end
  end

  def name_model(directory, version)
    File.join(directory, format('JOB1_Synthetic_Model_v%02d.skp', version))
  end

  def source_model(directory, version = 1)
    path = name_model(directory, version)
    model.instance_variable_set(:@path, path)
    path
  end

  def place(width, depth, height, x = 0, y = 0, z = 0)
    group = model.entities.add_group
    # FakeBounds is (X width, Y height, Z depth). Spec depth is Y and spec height is Z.
    group.drift_bounds(width, depth, height)
    group.translate([x, y, z])
    group
  end

  def spec_element(entity, type, x: 0, y: 0, z: 0)
    {
      'id' => entity.persistent_id,
      'type' => type,
      'x' => x,
      'y' => y,
      'z' => z,
      'width' => entity.bounds.width,
      'depth' => entity.bounds.height,
      'height' => entity.bounds.depth,
      'unit' => 'inches'
    }
  end

  # --- existing contract -------------------------------------------------

  def test_ping_reports_bounded_command_map
    result = @commands.execute('diagnostics.ping', {})

    assert_equal 'ok', result['status']
    assert_equal '2026.0', result['sketchup_version']
    assert_equal RUBY_VERSION, result['ruby_version']
    assert_equal 28, result['command_count']
    assert_equal Process.pid, result['host_pid']
    assert_equal DccMcp::SketchupAdapter::Commands::ADAPTER_VERSION, result['adapter_version']
    assert_equal File.expand_path('../../src/dcc_mcp_sketchup/sketchup_plugin', __dir__), result['plugin_path']
  end

  def test_adapter_version_matches_python_package_version
    version_file = File.expand_path('../../src/dcc_mcp_sketchup/__version__.py', __dir__)
    package_version = File.read(version_file).match(/__version__ = ["']([^"']+)["']/)[1]

    assert_equal package_version, DccMcp::SketchupAdapter::Commands::ADAPTER_VERSION
  end

  def test_add_box_uses_one_undo_operation_and_returns_persistent_id
    result = @commands.execute('geometry.add_box', box_params)

    assert_equal 101, result.dig('entity', 'persistent_id')
    assert_equal 'RubySmoke', model.entities.to_a.first.name
    assert_in_delta 19.685, model.entities.to_a.first.entities.face.pushed, 0.001
    assert_equal 1, model.commits
    assert_equal 0, model.aborts
  end

  def test_expired_request_is_rejected_before_host_access
    error = assert_raises(RuntimeError) do
      @commands.execute(
        'model.inspect',
        '_dcc_mcp_deadline_unix_ms' => ((Time.now.to_f - 1) * 1000).to_i
      )
    end

    assert_match(/expired/, error.message)
  end

  def test_unknown_command_is_rejected
    error = assert_raises(ArgumentError) { @commands.execute('ruby.eval', {}) }

    assert_match(/Unsupported SketchUp command/, error.message)
  end

  def test_import_converts_bounded_json_option_keys_to_symbols
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'source.dae')
      File.write(path, '<COLLADA/>')

      with_project(directory) do
      @commands.execute(
        'model.import',
        'path' => path,
        'options' => { 'units' => 'model', 'merge_coplanar_faces' => true }
      )

      assert_equal path, model.import_call[0]
      assert_equal({ units: 'model', merge_coplanar_faces: true }, model.import_call[1])
      end
    end
  end

  def test_export_accepts_current_official_format_and_symbolizes_options
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'scene.glb')

      with_project(directory) do
      @commands.execute('model.export', 'path' => path, 'options' => { 'selectionset_only' => false })

      assert_equal path, model.export_call[0]
      assert_equal({ selectionset_only: false }, model.export_call[1])
      end
    end
  end

  def test_import_rejects_unbounded_or_invalid_option_keys
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'source.dae')
      File.write(path, '<COLLADA/>')
      too_many = 65.times.to_h { |index| ["option_#{index}", true] }

      error = assert_raises(ArgumentError) do
        with_project(directory) do
          @commands.execute('model.import', 'path' => path, 'options' => too_many)
        end
      end
      assert_match(/at most 64 keys/, error.message)

      error = assert_raises(ArgumentError) do
        with_project(directory) do
          @commands.execute('model.import', 'path' => path, 'options' => { 'not-valid!' => true })
        end
      end
      assert_match(/must match/, error.message)
    end
  end

  def test_model_save_is_not_a_command
    error = assert_raises(ArgumentError) do
      @commands.execute('model.save', {})
    end

    assert_match(/Unsupported SketchUp command: model.save/, error.message)
  end

  def test_scale_is_rejected
    group = model.entities.add_group

    error = assert_raises(ArgumentError) do
      @commands.execute(
        'entity.transform',
        'entity_id' => group.persistent_id,
        'translation' => [1, 0, 0],
        'scale' => [2, 2, 2]
      )
    end

    assert_match(/Unexpected parameters: scale/, error.message)
    assert_equal 0, model.commits
  end

  def test_omitted_unit_is_inches
    result = @commands.execute('geometry.add_box', 'width' => 10, 'depth' => 5, 'height' => 8)
    extents = result.dig('verification', 'checks').find { |check| check['check'] == 'bounds_extents' }

    assert_equal 'inches', result['unit']
    assert_equal [10.0, 5.0, 8.0], extents['expected']
    assert_equal [10.0, 5.0, 8.0], extents['actual']
  end

  def test_string_parameters_do_not_coerce_other_json_types
    error = assert_raises(ArgumentError) do
      @commands.execute('geometry.add_box', 'width' => 1, 'depth' => 1, 'height' => 1, 'name' => 42)
    end

    assert_match(/must be a string/, error.message)
  end

  # --- api probe (drives the doctor's compatibility matrix check) ---------

  def test_api_probe_reports_presence_for_each_requested_symbol
    result = @commands.execute(
      'diagnostics.api_probe',
      'symbols' => ['Sketchup::Color#red', 'Sketchup::Nonexistent#method']
    )

    probe = result['probe']
    assert_equal 2, probe.length
    assert_equal true, probe[0]['present']
    assert_equal 'Sketchup::Color', probe[0]['owner']
    assert_equal 'red', probe[0]['symbol']
    assert_equal false, probe[1]['present']
    assert_equal RUBY_VERSION, result['ruby_version']
  end

  def test_api_probe_rejects_malformed_symbols
    error = assert_raises(ArgumentError) do
      @commands.execute('diagnostics.api_probe', 'symbols' => ['not a symbol'])
    end

    assert_match(/Owner#symbol/, error.message)
  end

  def test_api_probe_requires_symbols
    assert_raises(ArgumentError) { @commands.execute('diagnostics.api_probe', {}) }
  end

  # --- post-write read-back ----------------------------------------------

  def test_add_box_returns_verified_extents
    result = @commands.execute('geometry.add_box', box_params)
    verification = result['verification']

    assert_equal true, verification['verified']
    assert_equal 'geometry.add_box', verification['tool']
    assert_equal '2026.0', verification['host_version']
    names = verification['checks'].map { |check| check['check'] }
    assert_includes names, 'entity_present'
    assert_includes names, 'entity_name'
    assert_includes names, 'bounds_extents'

    # 2m x 1m x 0.5m expressed in inches, which is the unit bounds report.
    extents = verification['checks'].find { |check| check['check'] == 'bounds_extents' }
    assert_in_delta 78.740, extents['expected'][0], 0.001
    assert_in_delta 39.370, extents['expected'][1], 0.001
    assert_in_delta 19.685, extents['expected'][2], 0.001
    assert_equal extents['expected'], extents['actual']
  end

  def test_add_box_rejects_geometry_that_does_not_match_the_request
    # Simulate a pushpull that returned without producing the requested volume:
    # every newly created group reports a degenerate 1x1x1 bounding box.
    original = FakeGroup.instance_method(:apply_extents)
    FakeGroup.define_method(:apply_extents) do |_points, _height|
      @bounds = FakeBounds.new(1, 1, 1)
    end

    error = assert_raises(DccMcp::SketchupAdapter::VerificationFailure) do
      @commands.execute('geometry.add_box', box_params)
    end

    assert_match(/bounds_extents/, error.message)
    assert_match(/host SketchUp 2026.0/, error.message)
    assert_equal 'bounds_extents', error.payload['check']
    assert_equal 'geometry.add_box', error.payload['tool']
    assert_equal '2026.0', error.payload['host_version']
    assert_equal DccMcp::SketchupAdapter::Verification::ERROR_CODE, error.payload['code']

    # The read-back runs inside the undo operation, so a disagreement aborts it
    # instead of committing geometry that does not match the request.
    assert_equal 0, model.commits
    assert_equal 1, model.aborts
  ensure
    FakeGroup.define_method(:apply_extents, original)
  end

  def test_add_cylinder_returns_verified_diameter_and_height
    result = @commands.execute(
      'geometry.add_cylinder',
      'radius' => 0.5, 'height' => 2.0, 'unit' => 'meters'
    )
    extents = result['verification']['checks'].find { |check| check['check'] == 'bounds_extents' }

    assert_in_delta 39.370, extents['expected'][0], 0.001
    assert_in_delta 39.370, extents['expected'][1], 0.001
    assert_in_delta 78.740, extents['expected'][2], 0.001
    assert_equal extents['expected'], extents['actual']
  end

  def test_group_entities_verifies_the_members_were_moved_into_the_group
    first = model.entities.add_group
    second = model.entities.add_group

    result = @commands.execute('geometry.group', 'entity_ids' => [first.persistent_id, second.persistent_id])
    members = result['verification']['checks'].find { |check| check['check'] == 'group_member_count' }

    assert_equal 2, members['expected']
    assert_equal 2, members['actual']
  end

  def test_rename_entity_verifies_the_new_name
    group = model.entities.add_group

    result = @commands.execute('entity.rename', 'entity_id' => group.persistent_id, 'name' => 'Wall')
    rename = result['verification']['checks'].find { |check| check['check'] == 'entity_name' }

    assert_equal 'Wall', rename['expected']
    assert_equal 'Wall', rename['actual']
  end

  def test_rename_entity_rejects_a_name_that_did_not_stick
    group = model.entities.add_group
    # Simulate a host that accepted the setter but did not apply it.
    group.define_singleton_method(:name) { 'Stale' }

    error = assert_raises(DccMcp::SketchupAdapter::VerificationFailure) do
      @commands.execute('entity.rename', 'entity_id' => group.persistent_id, 'name' => 'Wall')
    end

    assert_equal 'entity_name', error.payload['check']
    assert_equal 'Wall', error.payload['expected']
    assert_equal 'Stale', error.payload['actual']
  end

  def test_erase_entities_verifies_nothing_resolves_afterwards
    group = model.entities.add_group

    result = with_approval do
      @commands.execute('entity.erase', 'entity_ids' => [group.persistent_id])
    end
    absent = result['verification']['checks'].find { |check| check['check'] == 'entity_absent' }

    assert_equal [], absent['expected']
    assert_equal [], absent['actual']
    assert_equal 0, model.entities.length
  end

  def test_select_entities_verifies_the_selection
    group = model.entities.add_group

    result = @commands.execute('entity.select', 'entity_ids' => [group.persistent_id])
    selected = result['verification']['checks'].find { |check| check['check'] == 'selection_contains' }

    assert_equal [group.persistent_id], selected['expected']
    assert_equal [group.persistent_id], selected['actual']
  end

  def test_transform_entity_verifies_the_centre_moved_by_the_translation
    group = model.entities.add_group
    group.drift_bounds(2, 2, 2)

    result = @commands.execute(
      'entity.transform',
      'entity_id' => group.persistent_id,
      'translation' => [1, 0, 0],
      'unit' => 'meters'
    )
    centre = result['verification']['checks'].find { |check| check['check'] == 'bounds_center' }

    # The centre starts at (1, 1, 1) and the translation is 1m = 39.37 inches.
    assert_in_delta 1 + 39.370, centre['expected'][0], 0.001
    assert_equal centre['expected'], centre['actual']
  end

  def test_transform_entity_rejects_a_transform_that_did_not_move_the_entity
    group = model.entities.add_group
    group.drift_bounds(2, 2, 2)
    model.entities.define_singleton_method(:transform_entities) { |_transformation, list| list }

    error = assert_raises(DccMcp::SketchupAdapter::VerificationFailure) do
      @commands.execute(
        'entity.transform',
        'entity_id' => group.persistent_id,
        'translation' => [1, 0, 0],
        'unit' => 'meters'
      )
    end

    assert_equal 'bounds_center', error.payload['check']
    refute_equal error.payload['expected'], error.payload['actual']
  end

  def test_wall_offset_of_one_sixteenth_matches
    wall = place(120.0, 6.0, 96.0, 1.0 / 16.0)
    before = model.commits

    result = @commands.execute('model.validate_spec', 'spec' => { 'elements' => [spec_element(wall, 'wall')] })
    item = result['elements'].first

    assert_equal 'MATCH', result['status']
    assert_equal 'MATCH', item['status']
    assert_equal false, result['edited']
    assert_in_delta 0.125, item['tolerance_inches'], 1e-12
    assert_in_delta 1.0 / 16.0, item['delta']['x'], 1e-9
    assert_equal 'inches', result['unit']
    assert_equal before, model.commits
  end

  def test_wall_offset_of_three_sixteenths_blocks
    wall = place(120.0, 6.0, 96.0, 3.0 / 16.0)

    result = @commands.execute('model.validate_spec', 'spec' => { 'elements' => [spec_element(wall, 'wall')] })

    assert_equal 'BLOCK', result['status']
    assert_equal 'BLOCK', result['elements'].first['status']
    assert_in_delta 3.0 / 16.0, result['elements'].first['delta']['x'], 1e-9
    assert_equal 0, model.commits
    assert_in_delta 3.0 / 16.0, wall.bounds.min.x, 1e-9
    assert_in_delta 120.0, wall.bounds.width, 1e-9
  end

  def test_wall_offset_of_exactly_one_eighth_matches
    wall = place(120.0, 6.0, 96.0, 1.0 / 8.0)

    result = @commands.execute('model.validate_spec', 'spec' => { 'elements' => [spec_element(wall, 'wall')] })

    assert_equal 'MATCH', result['status']
  end

  def test_appliance_offset_of_one_thirty_second_blocks
    appliance = place(36.0, 28.0, 70.0, 1.0 / 32.0)

    result = @commands.execute(
      'model.validate_spec', 'spec' => { 'elements' => [spec_element(appliance, 'appliance')] }
    )
    item = result['elements'].first

    assert_equal 'BLOCK', result['status']
    assert_equal 'BLOCK', item['status']
    assert_equal 0, item['tolerance_inches']
    assert_in_delta 1.0 / 32.0, item['delta']['x'], 1e-9
  end

  def test_missing_entity_blocks_without_editing
    before = model.entities.length

    result = @commands.execute(
      'model.validate_spec',
      'spec' => {
        'elements' => [
          {
            'id' => 9_999_999, 'type' => 'wall',
            'x' => 0, 'y' => 0, 'z' => 0,
            'width' => 1, 'depth' => 1, 'height' => 1
          }
        ]
      }
    )

    assert_equal 'BLOCK', result['status']
    assert_nil result['elements'].first['available']
    assert_nil result['elements'].first['delta']
    assert_equal false, result['edited']
    assert_equal before, model.entities.length
    assert_equal 0, model.commits
  end

  def test_missing_axis_is_not_invented
    wall = place(10, 1, 8)
    element = spec_element(wall, 'wall')
    element.delete('width')

    result = @commands.execute('model.validate_spec', 'spec' => { 'elements' => [element] })

    assert_equal 'CANNOT VERIFY', result['status']
    assert_equal 'CANNOT VERIFY', result['elements'].first['status']
    assert_equal ['width'], result['elements'].first['missing_axes']
    assert_nil result['elements'].first['available']
    assert_equal 0, model.commits
  end

  def test_absent_type_is_not_invented
    wall = place(10, 1, 8)

    result = @commands.execute('model.validate_spec', 'spec' => { 'elements' => [spec_element(wall, 'wall')] })

    assert_equal 'MATCH', result['status']
    assert_nil result['elements'].first['available']['type']
  end

  def test_type_conflict_within_tolerance_is_a_mismatch
    wall = place(120.0, 6.0, 96.0)
    wall.set_attribute('renco', 'type', 'appliance')

    result = @commands.execute('model.validate_spec', 'spec' => { 'elements' => [spec_element(wall, 'wall')] })

    assert_equal 'MISMATCH', result['status']
    assert_equal 'appliance', result['elements'].first['available']['type']
    assert_equal 'wall', result['elements'].first['specified']['type']
  end

  def test_block_wins_over_mismatch
    wall = place(120.0, 6.0, 96.0)
    wall.set_attribute('renco', 'type', 'appliance')
    drifted = place(10.0, 10.0, 10.0, 1.0)

    result = @commands.execute(
      'model.validate_spec',
      'spec' => { 'elements' => [spec_element(wall, 'wall'), spec_element(drifted, 'wall')] }
    )

    assert_equal 'BLOCK', result['status']
  end

  def test_category_folders_do_not_move_geometry
    wall = place(100.0, 6.0, 90.0, 4, 5, 6)
    before = [wall.bounds.min.x, wall.bounds.min.y, wall.bounds.min.z, wall.bounds.width, wall.bounds.height, wall.bounds.depth]
    commits = model.commits

    result = @commands.execute('organize.categories', {})
    after = [wall.bounds.min.x, wall.bounds.min.y, wall.bounds.min.z, wall.bounds.width, wall.bounds.height, wall.bounds.depth]
    names = result['categories'].map { |item| item['folder'] }

    assert_equal before, after
    assert_includes names, 'Walls – Bedroom'
    assert_includes names, 'Appliances'
    codes = result['categories'].map { |item| item['tag'] }
    assert_includes codes, 'A-WALL-EXT'
    assert_includes codes, 'I-CABINETRY'
    assert_equal false, result['geometry_moved']
    assert_includes result.dig('verification', 'checks').map { |check| check['check'] }, "bounds_unchanged_#{wall.persistent_id}"
    assert_equal commits + 1, model.commits
  end

  def test_shared_room_is_logged_and_not_split
    shared = place(30.0, 20.0, 10.0, 2, 3, 4)
    only = place(12.0, 12.0, 12.0, 8, 0, 0)
    shared_before = [shared.bounds.min.x, shared.bounds.max.x, shared.bounds.min.y, shared.bounds.max.y]
    only_before = [only.bounds.width, only.bounds.height, only.bounds.depth]

    result = @commands.execute(
      'organize.rooms',
      'rooms' => [
        { 'name' => 'Kitchen', 'entity_ids' => [shared.persistent_id, only.persistent_id] },
        { 'name' => 'Living', 'entity_ids' => [shared.persistent_id] }
      ]
    )

    assert_equal false, result['geometry_moved']
    assert_equal [shared.bounds.min.x, shared.bounds.max.x, shared.bounds.min.y, shared.bounds.max.y], shared_before
    assert_equal [only.bounds.width, only.bounds.height, only.bounds.depth], only_before
    assert_includes model.entities.to_a, shared
    refute_includes model.entities.to_a, only
    rooms = result['shared'].select { |item| item['entity_id'] == shared.persistent_id }
    assert_equal %w[Kitchen Living], rooms.map { |item| item['room'] }
    assert_equal [false, false], rooms.map { |item| item['split'] }
    assert_equal %w[Kitchen Living], shared.get_attribute('renco', 'rooms')
    room_group = model.entities.to_a.find { |item| item.respond_to?(:name) && item.name == 'Kitchen' }
    assert_includes room_group.entities.to_a, only
    refute_includes room_group.entities.to_a, shared
  end

  def test_outliner_reads_nested_groups_components_and_attributes
    outer = model.entities.add_group
    outer.name = 'Walls'
    inner = outer.entities.add_group
    inner.name = 'Stud'
    definition = FakeComponentDefinition.new('RangeDef')
    shelf = FakeGroup.new
    shelf.name = 'Shelf'
    definition.entities << shelf
    instance = FakeComponentInstance.new(definition)
    instance.name = 'Range'
    instance.set_attribute('renco', 'id', 'A-1')
    model.entities.add_existing(instance)
    model.register(instance)

    result = @commands.execute('model.outliner', {})
    nodes = result['hierarchy']
    wall = nodes.find { |node| node['name'] == 'Walls' }
    range = nodes.find { |node| node['name'] == 'Range' }

    assert_equal 'Group', wall['type']
    assert_equal inner.persistent_id, wall['children'].first['persistent_id']
    assert_equal 'Stud', wall['children'].first['name']
    assert_equal 'ComponentInstance', range['type']
    assert_equal instance.persistent_id, range['persistent_id']
    assert_equal instance.entityID, range['entity_id']
    assert_equal 'A-1', range.dig('attributes', 'renco', 'id')
    assert_equal 'Shelf', range['children'].first['name']
    assert_equal 'inches', result['unit']
    refute_includes result.keys, 'verification'
  end

  def test_attribute_write_is_one_undo
    group = model.entities.add_group
    commits = model.commits

    result = @commands.execute(
      'attributes.set',
      'entity_id' => group.persistent_id,
      'dictionary' => 'renco',
      'key' => 'type',
      'value' => 'wall'
    )

    assert_equal 'wall', group.get_attribute('renco', 'type')
    assert_equal true, result.dig('verification', 'verified')
    assert_equal commits + 1, model.commits
    assert_equal 0, model.aborts
  end

  def test_scene_lifecycle_is_verified
    @commands.execute('scenes.create', 'name' => 'Shot 1', 'description' => 'wide')
    update = @commands.execute('scenes.update', 'name' => 'Shot 1', 'new_name' => 'Shot 2')
    assert_equal 'Shot 2', update.dig('verification', 'checks')
                                 .find { |check| check['check'] == 'scene_present' }['actual']

    removal = with_approval { @commands.execute('scenes.remove', 'name' => 'Shot 2') }
    absent = removal.dig('verification', 'checks').find { |check| check['check'] == 'scene_absent' }
    assert_equal false, absent['actual']
  end

  def test_scene_update_rejects_a_rename_that_did_not_apply
    model.pages.add('Shot 1')
    model.pages.define_singleton_method(:add) { |name| Sketchup::Page.new(name) }
    page = model.pages.first
    page.define_singleton_method(:name=) { |_value| nil }

    error = assert_raises(DccMcp::SketchupAdapter::VerificationFailure) do
      @commands.execute('scenes.update', 'name' => 'Shot 1', 'new_name' => 'Shot 2')
    end

    assert_equal 'scene_present', error.payload['check']
    assert_equal 'Shot 2', error.payload['expected']
    assert_nil error.payload['actual']
  end

  def test_tag_lifecycle_is_verified
    @commands.execute('tags.create', 'name' => 'Walls', 'visible' => false)
    update = @commands.execute('tags.list', {})
    assert_includes update['tags'].map { |tag| tag['name'] }, 'Walls'

    removal = with_approval { @commands.execute('tags.remove', 'name' => 'Walls') }
    absent = removal.dig('verification', 'checks').find { |check| check['check'] == 'tag_absent' }
    assert_equal false, absent['actual']
  end

  def test_tag_remove_rejects_a_tag_that_survived
    model.layers.add('Walls')
    model.layers.define_singleton_method(:remove) { |_layer| true }

    error = assert_raises(DccMcp::SketchupAdapter::VerificationFailure) do
      with_approval { @commands.execute('tags.remove', 'name' => 'Walls') }
    end

    assert_equal 'tag_absent', error.payload['check']
    assert_equal true, error.payload['actual']
  end

  def test_assign_tag_verifies_the_entity_moved
    group = model.entities.add_group
    model.layers.add('Walls')

    result = @commands.execute('tags.assign', 'entity_id' => group.persistent_id, 'tag' => 'Walls')
    assigned = result.dig('verification', 'checks').find { |check| check['check'] == 'entity_tag' }

    assert_equal 'Walls', assigned['expected']
    assert_equal 'Walls', assigned['actual']
  end

  def test_save_copy_writes_a_new_versioned_file
    Dir.mktmpdir do |directory|
      source_model(directory, 1)
      path = name_model(directory, 2)

      result = with_project(directory) do
        @commands.execute('model.save_copy', 'path' => path)
      end

      assert_equal true, result.dig('verification', 'verified')
      assert File.file?(path)
      assert_includes result.dig('verification', 'checks').map { |check| check['check'] }, 'source_path_unchanged'
    end
  end

  def test_overwrite_is_refused
    Dir.mktmpdir do |directory|
      source_model(directory, 1)
      path = name_model(directory, 2)

      error = assert_raises(ArgumentError) do
        with_project(directory) do
          @commands.execute('model.save_copy', 'path' => path, 'overwrite' => true)
        end
      end

      assert_match(/Unexpected parameters: overwrite/, error.message)
      refute File.file?(path)
    end
  end

  def test_existing_save_target_is_refused
    Dir.mktmpdir do |directory|
      source_model(directory, 1)
      path = name_model(directory, 2)
      File.write(path, 'already here')

      error = assert_raises(ArgumentError) do
        with_project(directory) do
          @commands.execute('model.save_copy', 'path' => path)
        end
      end

      assert_match(/save target already exists/, error.message)
      assert_equal 'already here', File.read(path)
    end
  end

  def test_save_copy_refuses_the_source_path
    Dir.mktmpdir do |directory|
      path = source_model(directory, 1)

      error = assert_raises(ArgumentError) do
        with_project(directory) do
          @commands.execute('model.save_copy', 'path' => path)
        end
      end

      assert_match(/strictly higher than the source/, error.message)
      refute File.file?(path)
    end
  end

  def test_save_copy_refuses_a_different_base_name
    Dir.mktmpdir do |directory|
      source_model(directory, 1)
      path = File.join(directory, 'JOB9_Other_Model_v02.skp')

      error = assert_raises(ArgumentError) do
        with_project(directory) do
          @commands.execute('model.save_copy', 'path' => path)
        end
      end

      assert_match(/base name must match the source model/, error.message)
    end
  end

  def test_unversioned_save_name_is_refused
    Dir.mktmpdir do |directory|
      source_model(directory, 1)
      path = File.join(directory, 'model.skp')

      error = assert_raises(ArgumentError) do
        with_project(directory) do
          @commands.execute('model.save_copy', 'path' => path)
        end
      end

      assert_match(/JobID>_<Project>_Model_v<NN>/, error.message)
    end
  end

  def test_path_outside_the_project_folder_is_refused
    Dir.mktmpdir do |project|
      Dir.mktmpdir do |outside|
        source_model(project, 1)
        path = File.join(outside, 'JOB1_Synthetic_Model_v02.skp')

        error = assert_raises(ArgumentError) do
          with_project(project) do
            @commands.execute('model.save_copy', 'path' => path)
          end
        end

        assert_match(/outside the project folder/, error.message)
        refute File.file?(path)
      end
    end
  end

  def test_symlink_escape_is_refused
    Dir.mktmpdir do |project|
      Dir.mktmpdir do |outside|
        link = File.join(project, 'escape')
        File.symlink(outside, link)
        path = File.join(link, 'scene.dae')

        error = assert_raises(ArgumentError) do
          with_project(project) do
            @commands.execute('model.export', 'path' => path)
          end
        end

        assert_match(/outside the project folder/, error.message)
      end
    end
  end

  def test_file_symlink_is_refused_for_save_export_and_import
    Dir.mktmpdir do |project|
      Dir.mktmpdir do |outside|
        source_model(project, 1)
        outside_file = File.join(outside, 'secret.skp')
        File.write(outside_file, 'secret')
        save_link = name_model(project, 2)
        File.symlink(outside_file, save_link)
        export_link = File.join(project, 'scene.glb')
        File.symlink(File.join(outside, 'scene.glb'), export_link)
        import_link = File.join(project, 'source.dae')
        File.write(File.join(outside, 'source.dae'), '<COLLADA/>')
        File.symlink(File.join(outside, 'source.dae'), import_link)

        with_project(project) do
          save_error = assert_raises(ArgumentError) do
            @commands.execute('model.save_copy', 'path' => save_link)
          end
          export_error = assert_raises(ArgumentError) do
            @commands.execute('model.export', 'path' => export_link)
          end
          import_error = assert_raises(ArgumentError) do
            @commands.execute('model.import', 'path' => import_link)
          end

          assert_match(/symlink/, save_error.message)
          assert_match(/symlink/, export_error.message)
          assert_match(/symlink/, import_error.message)
          assert_equal 'secret', File.read(outside_file)
        end
      end
    end
  end

  def test_unset_project_folder_fails_closed
    Dir.mktmpdir do |directory|
      path = name_model(directory, 2)
      ENV.delete('DCC_MCP_SKETCHUP_PROJECT_FOLDER')

      error = assert_raises(ArgumentError) do
        @commands.execute('model.save_copy', 'path' => path)
      end

      assert_match(/project folder is not configured/, error.message)
    end
  end

  def test_export_verifies_the_output_file
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'scene.glb')

      result = with_project(directory) do
        @commands.execute('model.export', 'path' => path)
      end

      assert_equal true, result.dig('verification', 'verified')
      assert File.file?(path)
    end
  end

  def test_existing_export_target_is_refused
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'scene.glb')
      File.write(path, 'keep')

      error = assert_raises(ArgumentError) do
        with_project(directory) do
          @commands.execute('model.export', 'path' => path)
        end
      end

      assert_match(/save target already exists/, error.message)
      assert_equal 'keep', File.read(path)
    end
  end

  def test_export_rejects_a_successful_call_that_wrote_nothing
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'scene.glb')
      model.define_singleton_method(:export) { |_target, _options = nil| true }

      error = assert_raises(DccMcp::SketchupAdapter::VerificationFailure) do
        with_project(directory) do
          @commands.execute('model.export', 'path' => path)
        end
      end

      assert_equal 'file_exists', error.payload['check']
      assert_equal true, error.payload['expected']
      assert_equal false, error.payload['actual']
    end
  end

  def test_import_verifies_geometry_was_not_lost
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'source.dae')
      File.write(path, '<COLLADA/>')

      result = with_project(directory) do
        @commands.execute('model.import', 'path' => path)
      end
      checks = result['verification']['checks'].map { |check| check['check'] }

      assert_includes checks, 'root_entity_count_not_decreased'
      assert_includes checks, 'source_file_readable'
    end
  end

  # --- the contract itself -----------------------------------------------

  def test_every_mutating_command_returns_a_verified_block
    mutating = %w[
      model.save_copy model.import model.export
      geometry.add_box geometry.add_cylinder geometry.group
      entity.rename entity.transform attributes.set
      organize.categories organize.rooms
      entity.select entity.erase
      scenes.create scenes.update scenes.remove
      tags.create tags.assign tags.remove
    ]

    Dir.mktmpdir do |directory|
      File.write(File.join(directory, 'source.dae'), '<COLLADA/>')
      model.entities.add_group
      model.pages.add('Shot 1')
      model.layers.add('Walls')
      source_model(directory, 1)

      with_approval do
        with_project(directory) do
        mutating.each do |name|
          first = model.entities.first
          params = case name
                   when 'model.save_copy' then { 'path' => name_model(directory, 2) }
                   when 'model.export' then { 'path' => File.join(directory, 'scene.glb') }
                   when 'model.import' then { 'path' => File.join(directory, 'source.dae') }
                   when 'geometry.add_box' then box_params
                   when 'geometry.add_cylinder' then { 'radius' => 0.5, 'height' => 2.0 }
                   when 'geometry.group' then { 'entity_ids' => [first.persistent_id] }
                   when 'entity.rename' then { 'entity_id' => first.persistent_id, 'name' => 'Wall' }
                   when 'entity.transform' then { 'entity_id' => first.persistent_id, 'translation' => [1, 0, 0] }
                   when 'entity.erase', 'entity.select' then { 'entity_ids' => [first.persistent_id] }
                   when 'attributes.set' then { 'entity_id' => first.persistent_id, 'dictionary' => 'renco', 'key' => 'type', 'value' => 'wall' }
                   when 'organize.rooms' then { 'rooms' => [{ 'name' => 'Kitchen', 'entity_ids' => [first.persistent_id] }] }
                   when 'scenes.create' then { 'name' => 'Shot 2' }
                   when 'scenes.update' then { 'name' => 'Shot 2', 'new_name' => 'Shot 3' }
                   when 'scenes.remove' then { 'name' => 'Shot 1' }
                   when 'tags.create' then { 'name' => 'CustomTag' }
                   when 'tags.assign' then { 'entity_id' => first.persistent_id, 'tag' => 'Walls' }
                   when 'tags.remove' then { 'name' => 'CustomTag' }
                   else {}
                   end

          result = @commands.execute(name, params)
          assert_equal true, result.dig('verification', 'verified'), "#{name} returned no verified read-back"
          refute_empty result.dig('verification', 'checks'), "#{name} verified with no checks"
          assert_equal name, result.dig('verification', 'tool')
        end
        end
      end
    end
  end

  def test_read_only_commands_carry_no_verification_block
    wall = place(10, 1, 8)
    calls = {
      'diagnostics.ping' => {},
      'model.inspect' => {},
      'model.list_entities' => {},
      'model.validate' => {},
      'model.validate_spec' => { 'spec' => { 'elements' => [spec_element(wall, 'wall')] } },
      'model.outliner' => {},
      'scenes.list' => {},
      'tags.list' => {}
    }
    calls.each do |name, params|
      result = @commands.execute(name, params)

      refute_includes result.keys, 'verification', name
      if name == 'diagnostics.ping'
        refute_includes result.keys, 'unit'
      end
      if name == 'model.inspect'
        assert_equal 'inches', result['unit']
      end
    end
  end

  def test_any_appliance_or_package_difference_is_block
    appliance = place(30.0, 24.0, 36.0)
    package = place(30.0, 24.0, 36.0, 40, 0, 0)
    larger = spec_element(appliance, 'appliance')
    larger['width'] = 29.0
    smaller = spec_element(package, 'package')
    smaller['height'] = 36.5
    commits = model.commits

    result = @commands.execute(
      'model.validate_spec',
      'spec' => { 'elements' => [larger, smaller] }
    )
    appliance_row = result['elements'][0]
    package_row = result['elements'][1]

    assert_equal 'BLOCK', result['status']
    assert_equal 'BLOCK', appliance_row['status']
    assert_equal 'BLOCK', package_row['status']
    assert_in_delta 1.0, appliance_row.dig('delta', 'width'), 1e-9
    assert_in_delta(-0.5, package_row.dig('delta', 'height'), 1e-9)
    assert_equal 30.0, appliance_row.dig('specified', 'width')
    assert_equal 30.0, appliance_row.dig('available', 'width')
    refute_includes result.to_s, 'filler'
    assert_equal commits, model.commits
  end

  def test_opening_uses_the_wall_tolerance
    opening = place(36.0, 6.0, 80.0)
    element = spec_element(opening, 'opening')
    element['width'] = 36.125

    result = @commands.execute('model.validate_spec', 'spec' => { 'elements' => [element] })

    assert_equal 'MATCH', result['elements'][0]['status']
  end

  def test_product_difference_is_block
    product = place(20.0, 20.0, 20.0)
    element = spec_element(product, 'product')
    element['depth'] = 20.0625

    result = @commands.execute('model.validate_spec', 'spec' => { 'elements' => [element] })

    assert_equal 'BLOCK', result['elements'][0]['status']
    assert_in_delta(-0.0625, result['elements'][0].dig('delta', 'depth'), 1e-9)
  end

  def test_missing_axis_is_cannot_verify
    wall = place(10.0, 1.0, 8.0)
    element = spec_element(wall, 'wall')
    element.delete('height')
    element.delete('depth')

    result = @commands.execute('model.validate_spec', 'spec' => { 'elements' => [element] })

    assert_equal 'CANNOT VERIFY', result['status']
    assert_equal 'CANNOT VERIFY', result['elements'][0]['status']
    assert_equal %w[depth height], result['elements'][0]['missing_axes']
  end

  def test_rotated_and_nested_entities_are_cannot_verify
    outer = place(10.0, 10.0, 10.0)
    nested = outer.entities.add_group
    nested.drift_bounds(4, 4, 4)
    rotated = place(8.0, 8.0, 8.0, 20, 0, 0)
    axis = Struct.new(:x, :y, :z)
    transform = Struct.new(:xaxis, :yaxis, :zaxis).new(
      axis.new(0.707, 0.707, 0.0),
      axis.new(-0.707, 0.707, 0.0),
      axis.new(0.0, 0.0, 1.0)
    )
    rotated.define_singleton_method(:transformation) { transform }
    before = [rotated.bounds.min.x, nested.bounds.width]

    result = @commands.execute(
      'model.validate_spec',
      'spec' => {
        'elements' => [spec_element(rotated, 'wall'), spec_element(nested, 'appliance', x: 0, y: 0, z: 0).merge(
          'width' => 4.0, 'depth' => 4.0, 'height' => 4.0
        )]
      }
    )

    assert_equal 'CANNOT VERIFY', result['status']
    assert_match(/rotated/, result['elements'][0]['reason'])
    assert_match(/nested/, result['elements'][1]['reason'])
    assert_equal before, [rotated.bounds.min.x, nested.bounds.width]
  end

  def test_contact_gap_and_overlap_are_reported_without_moving_geometry
    left = place(10.0, 10.0, 10.0, 0, 0, 0)
    touching = place(10.0, 10.0, 10.0, 10, 0, 0)
    gapped = place(10.0, 10.0, 10.0, 22, 0, 0)
    overlapping = place(10.0, 10.0, 10.0, 5, 0, 0)
    before = [left, touching, gapped, overlapping].map { |item| [item.bounds.min.x, item.bounds.width] }
    commits = model.commits

    result = @commands.execute(
      'model.validate_spec',
      'spec' => {
        'elements' => [left, touching, gapped, overlapping].map { |item| spec_element(item, 'wall') }
      }
    )
    relations = result['contacts'].map { |item| [item['left_id'], item['right_id'], item['relation']] }

    assert_includes relations, [left.persistent_id, touching.persistent_id, 'contact']
    assert_includes relations, [left.persistent_id, gapped.persistent_id, 'gap']
    assert_includes relations, [left.persistent_id, overlapping.persistent_id, 'overlap']
    assert result['contacts'].all? { |item| item['edited'] == false }
    assert_equal before, [left, touching, gapped, overlapping].map { |item| [item.bounds.min.x, item.bounds.width] }
    assert_equal commits, model.commits
  end

  def test_attribute_dictionary_is_only_renco_and_type_is_write_once
    group = model.entities.add_group
    commits = model.commits

    error = assert_raises(ArgumentError) do
      @commands.execute(
        'attributes.set',
        'entity_id' => group.persistent_id,
        'dictionary' => 'dynamic_attributes',
        'key' => 'lenx',
        'value' => '10'
      )
    end
    assert_match(/dictionary must be renco/, error.message)
    assert_equal commits, model.commits

    @commands.execute(
      'attributes.set',
      'entity_id' => group.persistent_id,
      'dictionary' => 'renco',
      'key' => 'type',
      'value' => 'wall'
    )
    rewrite = assert_raises(ArgumentError) do
      @commands.execute(
        'attributes.set',
        'entity_id' => group.persistent_id,
        'dictionary' => 'renco',
        'key' => 'type',
        'value' => 'appliance'
      )
    end
    assert_match(/write-once/, rewrite.message)
    assert_equal 'wall', group.get_attribute('renco', 'type')

    with_approval do
      @commands.execute(
        'attributes.set',
        'entity_id' => group.persistent_id,
        'dictionary' => 'renco',
        'key' => 'type',
        'value' => 'appliance'
      )
    end
    assert_equal 'appliance', group.get_attribute('renco', 'type')
  end

  def test_nested_room_input_is_refused
    outer = place(10, 10, 10)
    nested = outer.entities.add_group
    nested.drift_bounds(4, 4, 4)
    before = [nested.bounds.min.x, nested.bounds.width]
    commits = model.commits

    error = assert_raises(ArgumentError) do
      @commands.execute(
        'organize.rooms',
        'rooms' => [{ 'name' => 'Kitchen', 'entity_ids' => [nested.persistent_id] }]
      )
    end

    assert_match(/BLOCKs non-root/, error.message)
    assert_equal before, [nested.bounds.min.x, nested.bounds.width]
    assert_equal commits, model.commits
  end

  def test_assign_tag_refuses_a_raw_face_or_edge
    face = model.entities.add_group
    face.define_singleton_method(:typename) { 'Face' }
    edge = model.entities.add_group
    edge.define_singleton_method(:typename) { 'Edge' }
    model.layers.add('Walls')

    face_error = assert_raises(ArgumentError) do
      @commands.execute('tags.assign', 'entity_id' => face.persistent_id, 'tag' => 'Walls')
    end
    edge_error = assert_raises(ArgumentError) do
      @commands.execute('tags.assign', 'entity_id' => edge.persistent_id, 'tag' => 'Walls')
    end

    assert_match(/raw Face or Edge/, face_error.message)
    assert_match(/raw Face or Edge/, edge_error.message)
    refute_equal 'Walls', face.layer.name.to_s
  end

  def test_delete_commands_refuse_without_owner_approval
    group = model.entities.add_group
    model.pages.add('Shot 1')
    model.layers.add('Walls')
    commits = model.commits

    erase_error = assert_raises(ArgumentError) do
      @commands.execute('entity.erase', 'entity_ids' => [group.persistent_id])
    end
    scene_error = assert_raises(ArgumentError) do
      @commands.execute('scenes.remove', 'name' => 'Shot 1')
    end
    tag_error = assert_raises(ArgumentError) do
      @commands.execute('tags.remove', 'name' => 'Walls')
    end

    assert_match(/owner approval/, erase_error.message)
    assert_match(/owner approval/, scene_error.message)
    assert_match(/owner approval/, tag_error.message)
    assert_equal commits, model.commits
    assert_equal 1, model.entities.length
  end
end
