# frozen_string_literal: true

require 'json'
require 'pathname'
require_relative 'verification'

module DccMcp
  module SketchupAdapter
    class Commands
      MAX_LIST_ITEMS = 500
      MAX_OPTION_KEYS = 64
      MAX_PROBE_SYMBOLS = 128
      ADAPTER_VERSION = '0.3.2' # x-release-please-version
      OPTION_KEY_PATTERN = /\A[a-z][a-z0-9_]{0,63}\z/.freeze
      PROBE_ENTRY_PATTERN = /\A[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*[#.][A-Za-z_][A-Za-z0-9_]*[?!=]?\z/.freeze
      IMPORT_EXTENSIONS = %w[.3ds .dae .dwg .dxf .ifc .kmz .obj .skp .stl].freeze
      EXPORT_EXTENSIONS = %w[.3ds .dae .dwg .dxf .fbx .glb .ifc .kmz .obj .pdf .usdz .wrl .xsi].freeze
      UNIT_FACTORS = {
        'inches' => 1.0,
        'feet' => 12.0,
        'millimeters' => 1.0 / 25.4,
        'centimeters' => 1.0 / 2.54,
        'meters' => 1.0 / 0.0254
      }.freeze
      DEFAULT_UNIT = 'inches'
      PROJECT_FOLDER_ENV = 'DCC_MCP_SKETCHUP_PROJECT_FOLDER'
      OWNER_APPROVAL_ENV = 'DCC_MCP_SKETCHUP_OWNER_APPROVAL'
      # <JobID>_<Project>_Model_v<NN>.skp. JobID and Project do not contain underscores.
      MODEL_FILE_NAME = /\A([A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)_([A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)_Model_v(\d+)\.skp\z/
      WALL_TOLERANCE_INCHES = 1.0 / 8.0
      PRODUCT_TOLERANCE_INCHES = 0.0
      # Float noise only. It is far smaller than 1/32", so a product offset
      # of that size is still BLOCK. It is not a modelling tolerance.
      COMPARE_EPSILON_INCHES = 1e-9
      SPEC_AXES = %w[x y z width depth height].freeze
      LENGTH_RESULT_KEYS = %w[bounds width depth height radius delta origin translation].freeze
      DRAWING_KINDS = %w[wall opening].freeze
      PRODUCT_KINDS = %w[appliance product package].freeze
      # Folder names stay human. The tag inside each folder is the RenCo code.
      CATEGORY_TAGS = {
        'Roof' => 'A-ROOF',
        'Slab' => 'A-SLAB',
        'Foundation' => 'A-FNDN',
        'Walls – Exterior' => 'A-WALL-EXT',
        'Walls – Bedroom' => 'A-WALL-BED',
        'Walls – Bathroom' => 'A-WALL-BATH',
        'Walls – Kitchen' => 'A-WALL-KIT',
        'Doors' => 'A-DOOR',
        'Windows' => 'A-GLAZ',
        'Cabinetry' => 'I-CABINETRY',
        'Appliances' => 'I-APPL',
        'Stairs' => 'A-STRS',
        'Site' => 'L-SITE',
        'Reference' => 'G-REF'
      }.freeze

      def initialize
        @commands = {
          'diagnostics.ping' => method(:ping),
          'diagnostics.api_probe' => method(:api_probe),
          'model.inspect' => method(:inspect_model),
          'model.list_entities' => method(:list_entities),
          'model.save_copy' => method(:save_copy),
          'model.validate' => method(:validate_model),
          'model.validate_spec' => method(:validate_spec),
          'model.outliner' => method(:outliner),
          'model.import' => method(:import_model),
          'model.export' => method(:export_model),
          'geometry.add_box' => method(:add_box),
          'geometry.add_cylinder' => method(:add_cylinder),
          'geometry.group' => method(:group_entities),
          'entity.transform' => method(:transform_entity),
          'entity.rename' => method(:rename_entity),
          'entity.erase' => method(:erase_entities),
          'entity.select' => method(:select_entities),
          'attributes.set' => method(:set_attribute),
          'scenes.list' => method(:list_scenes),
          'scenes.create' => method(:create_scene),
          'scenes.update' => method(:update_scene),
          'scenes.remove' => method(:remove_scene),
          'tags.list' => method(:list_tags),
          'tags.create' => method(:create_tag),
          'tags.assign' => method(:assign_tag),
          'tags.remove' => method(:remove_tag),
          'organize.categories' => method(:organize_categories),
          'organize.rooms' => method(:organize_rooms)
        }.freeze
      end

      def execute(command_name, params)
        command = @commands[command_name]
        raise ArgumentError, "Unsupported SketchUp command: #{command_name}" unless command

        values = params.dup
        deadline = values.delete('_dcc_mcp_deadline_unix_ms')
        if deadline && integer(deadline, 'deadline') < (Time.now.to_f * 1000).to_i
          raise 'SketchUp request expired before main-thread execution'
        end
        result = command.call(values)
        result = with_length_unit(result)
        result
      end

      private

      def ping(params)
        require_keys(params, [])
        {
          'status' => 'ok',
          'sketchup_version' => Sketchup.version.to_s,
          'ruby_version' => RUBY_VERSION.to_s,
          'host_pid' => Process.pid,
          'adapter_version' => ADAPTER_VERSION,
          'plugin_path' => File.expand_path(__dir__),
          'host_thread_id' => Thread.current.object_id,
          'command_count' => @commands.length,
          'model_valid' => model.valid?
        }
      end

      # Answer "does this host expose the API the adapter depends on?" without
      # the Ruby side owning a second copy of the list. The caller (the Python
      # doctor) reads the symbols out of compat_matrix.json and sends them, so
      # the matrix stays the single source of truth across both runtimes.
      def api_probe(params)
        require_keys(params, %w[symbols], %w[symbols])
        symbols = params['symbols']
        raise ArgumentError, 'symbols must be an array' unless symbols.is_a?(Array)
        raise ArgumentError, "symbols must contain at most #{MAX_PROBE_SYMBOLS} entries" if symbols.length > MAX_PROBE_SYMBOLS

        {
          'status' => 'ok',
          'sketchup_version' => Sketchup.version.to_s,
          'ruby_version' => RUBY_VERSION.to_s,
          'probe' => symbols.map { |entry| probe_entry(entry) }
        }
      end

      def inspect_model(params)
        require_keys(params, [])
        entities = model.entities.to_a
        type_counts = entities.each_with_object(Hash.new(0)) do |entity, counts|
          counts[entity.typename.to_s] += 1
        end
        {
          'title' => model.title.to_s,
          'name' => model.name.to_s,
          'path' => model.path.to_s,
          'guid' => model.guid.to_s,
          'modified' => model.modified?,
          'valid' => model.valid?,
          'root_entity_count' => entities.length,
          'root_entity_types' => type_counts.sort.to_h,
          'material_count' => model.materials.length,
          'scene_count' => model.pages.length,
          'tag_count' => model.layers.length,
          'selection_count' => model.selection.length,
          'active_edit_depth' => Array(model.active_path).length,
          'bounds' => bounds_summary(model.bounds)
        }
      end

      def list_entities(params)
        require_keys(params, %w[kind limit])
        kind = optional_string(params['kind'])
        limit = params.key?('limit') ? integer(params['limit'], 'limit', 1, MAX_LIST_ITEMS) : 200
        values = model.entities.to_a
        values.select! { |entity| entity.typename.to_s.casecmp?(kind) } if kind
        {
          'entities' => values.first(limit).map { |entity| entity_summary(entity) },
          'total' => values.length,
          'truncated' => values.length > limit,
          'scope' => 'root'
        }
      end

      # save_copy is the only save. The name is <JobID>_<Project>_Model_v<NN>.skp,
      # the base name matches the source, and the version is strictly higher.
      # There is no overwrite flag and no model.save-with-no-path.
      def save_copy(params)
        require_keys(params, %w[path], %w[path])
        path = versioned_project_file(params['path'])
        source = current_model_path
        if source && same_path?(path, source)
          raise ArgumentError, 'save_copy path must differ from the source path'
        end
        raise ArgumentError, "save target already exists: #{path}" if path_exists?(path)

        before_path = model.path.to_s
        result = model.save_copy(path)
        raise 'SketchUp did not save the model copy' unless result

        checks = []
        Verification.check_file_written!('model.save_copy', checks, path)
        Verification.check!('model.save_copy', checks, 'source_path_unchanged', before_path, model.path.to_s)
        { 'path' => path, 'saved' => true, 'current_model_path' => model.path.to_s }
          .merge(Verification.verified('model.save_copy', checks))
      end

      def validate_model(params)
        require_keys(params, [])
        invalid = model.entities.to_a.reject(&:valid?)
        {
          'valid' => model.valid? && invalid.empty?,
          'invalid_root_entity_ids' => invalid.map { |entity| persistent_id(entity) },
          'modified' => model.modified?,
          'root_entity_count' => model.entities.length
        }
      end

      def import_model(params)
        require_keys(params, %w[path options], %w[path])
        path = require_project_path(input_file(params['path'], 'path', IMPORT_EXTENSIONS), 'path')
        options = symbol_keyed_options(params.fetch('options', {}), 'options')
        before_count = model.entities.length
        result = options.empty? ? model.import(path) : model.import(path, options)
        raise "SketchUp import failed: #{path}" unless result

        after_count = model.entities.length
        checks = []
        # Import must not remove geometry. A count increase is the expected
        # outcome but is not asserted, because a legitimate import can add
        # nothing to the root context (for example a file that imports entirely
        # into a definition). Losing entities, however, is never legitimate.
        Verification.check_count_not_decreased!('model.import', checks, before_count, after_count)
        Verification.check!('model.import', checks, 'source_file_readable', true, File.file?(path))
        {
          'path' => path, 'imported' => true, 'root_entity_count' => after_count
        }.merge(Verification.verified('model.import', checks))
      end

      def export_model(params)
        require_keys(params, %w[path options], %w[path])
        path = require_project_path(output_file(params['path'], 'path', EXPORT_EXTENSIONS), 'path')
        raise ArgumentError, "save target already exists: #{path}" if path_exists?(path)
        options = symbol_keyed_options(params.fetch('options', {}), 'options')
        result = options.empty? ? model.export(path) : model.export(path, options)
        raise "SketchUp export failed: #{path}" unless result

        checks = []
        Verification.check_file_written!('model.export', checks, path)
        { 'path' => path, 'exported' => true, 'exists' => File.file?(path) }
          .merge(Verification.verified('model.export', checks))
      end

      def add_box(params)
        require_keys(params, %w[origin width depth height unit name], %w[width depth height])
        unit = unit_name(params.fetch('unit', DEFAULT_UNIT))
        origin = point(params.fetch('origin', [0, 0, 0]), 'origin', unit)
        width = positive_length(params['width'], 'width', unit)
        depth = positive_length(params['depth'], 'depth', unit)
        height = positive_length(params['height'], 'height', unit)
        name = optional_string(params['name']) || 'DCC-MCP Box'
        created = nil
        checks = []
        with_operation('DCC-MCP Add Box') do
          group = model.entities.add_group
          group.name = name
          points = [
            origin,
            offset_point(origin, width, 0, 0),
            offset_point(origin, width, depth, 0),
            offset_point(origin, 0, depth, 0)
          ]
          face = group.entities.add_face(points)
          raise 'SketchUp could not create the box base face' unless face

          face.reverse! if face.normal.z.negative?
          face.pushpull(height)
          created = group
          verify_added_geometry('geometry.add_box', checks, group, name, [width, depth, height])
        end
        { 'entity' => entity_summary(created), 'unit' => unit }
          .merge(Verification.verified('geometry.add_box', checks))
      end

      def add_cylinder(params)
        require_keys(
          params,
          %w[center radius height segments unit name],
          %w[radius height]
        )
        unit = unit_name(params.fetch('unit', DEFAULT_UNIT))
        center = point(params.fetch('center', [0, 0, 0]), 'center', unit)
        radius = positive_length(params['radius'], 'radius', unit)
        height = positive_length(params['height'], 'height', unit)
        segments = integer(params.fetch('segments', 24), 'segments', 3, 128)
        name = optional_string(params['name']) || 'DCC-MCP Cylinder'
        created = nil
        checks = []
        with_operation('DCC-MCP Add Cylinder') do
          group = model.entities.add_group
          group.name = name
          edges = group.entities.add_circle(center, [0, 0, 1], radius, segments)
          face = group.entities.add_face(edges)
          raise 'SketchUp could not create the cylinder base face' unless face

          face.reverse! if face.normal.z.negative?
          face.pushpull(height)
          created = group
          verify_added_geometry(
            'geometry.add_cylinder', checks, group, name,
            [radius * 2, radius * 2, height]
          )
        end
        { 'entity' => entity_summary(created), 'segments' => segments, 'unit' => unit }
          .merge(Verification.verified('geometry.add_cylinder', checks))
      end

      # Shared read-back for the two primitives built by push-pulling a base
      # face. It proves three independent things: the group survives a round
      # trip through the persistent id index, it carries the requested name, and
      # the bounding box has the requested extents -- the last one is what
      # catches a pushpull that silently produced no volume.
      def verify_added_geometry(tool, checks, group, name, expected_extents)
        identifier = persistent_id(group)
        found = Verification.check_entity_present!(tool, checks, model, identifier)
        return if found.nil?

        Verification.check_entity_name!(tool, checks, found, name)
        Verification.check_extents!(tool, checks, found, expected_extents.map(&:to_f))
      end

      def group_entities(params)
        require_keys(params, %w[entity_ids name], %w[entity_ids])
        entities = root_entities(params['entity_ids'])
        name = optional_string(params['name']) || 'DCC-MCP Group'
        created = nil
        checks = []
        with_operation('DCC-MCP Group Entities') do
          created = model.entities.add_group(entities)
          created.name = name
          identifier = persistent_id(created)
          found = Verification.check_entity_present!('geometry.group', checks, model, identifier)
          unless found.nil?
            Verification.check_entity_name!('geometry.group', checks, found, name)
            Verification.check_group_members!('geometry.group', checks, found, entities.length)
          end
        end
        { 'entity' => entity_summary(created), 'grouped_count' => entities.length }
          .merge(Verification.verified('geometry.group', checks))
      end

      def transform_entity(params)
        require_keys(
          params,
          %w[entity_id translation rotation_axis rotation_degrees unit],
          %w[entity_id]
        )
        entity = root_entity(params['entity_id'])
        unit = unit_name(params.fetch('unit', DEFAULT_UNIT))
        translation = vector(params.fetch('translation', [0, 0, 0]), 'translation', unit)
        axis = numeric_triplet(params.fetch('rotation_axis', [0, 0, 1]), 'rotation_axis')
        raise ArgumentError, 'rotation_axis must not be zero' if axis.all?(&:zero?)

        degrees = number(params.fetch('rotation_degrees', 0), 'rotation_degrees', -360_000, 360_000)
        center = entity.respond_to?(:bounds) ? entity.bounds.center : Geom::Point3d.new(0, 0, 0)
        before_center = entity.respond_to?(:bounds) ? Verification.centre(entity.bounds) : nil
        transformation = Geom::Transformation.translation(translation)
        transformation *= Geom::Transformation.rotation(center, axis, degrees.degrees)
        checks = []
        with_operation('DCC-MCP Transform Entity') do
          unless model.entities.transform_entities(transformation, [entity])
            raise "SketchUp could not transform entity: #{persistent_id(entity)}"
          end

          # transform_entities returns an entity array on some builds and a
          # truthy count on others, so the return value is not a success
          # signal. The read-back is: rotation is applied about the entity
          # centre, which leaves the centre invariant, so the centre must have
          # moved by exactly the requested translation. Scale is not accepted.
          if before_center && entity.respond_to?(:bounds)
            Verification.check_center_moved!(
              'entity.transform', checks, entity, before_center, translation
            )
          else
            Verification.check!('entity.transform', checks, 'entity_present', true, entity.valid?)
          end
        end
        { 'entity' => entity_summary(entity), 'unit' => unit }
          .merge(Verification.verified('entity.transform', checks))
      end

      def rename_entity(params)
        require_keys(params, %w[entity_id name], %w[entity_id name])
        entity = entity(params['entity_id'])
        raise ArgumentError, 'entity does not support names' unless entity.respond_to?(:name=)

        name = non_empty_string(params['name'], 'name')
        checks = []
        with_operation('DCC-MCP Rename Entity') do
          entity.name = name
          Verification.check_entity_present!(
            'entity.rename', checks, model, persistent_id(entity)
          )
          Verification.check_entity_name!('entity.rename', checks, entity, name)
        end
        { 'entity' => entity_summary(entity) }
          .merge(Verification.verified('entity.rename', checks))
      end

      def erase_entities(params)
        require_owner_approval!('entity.erase')
        require_keys(params, %w[entity_ids], %w[entity_ids])
        entities = root_entities(params['entity_ids'])
        ids = entities.map { |item| persistent_id(item) }
        checks = []
        with_operation('DCC-MCP Erase Entities') do
          model.entities.erase_entities(entities)
          Verification.check_absent!('entity.erase', checks, model, ids, 'entity')
        end
        { 'erased_entity_ids' => ids, 'erased_count' => ids.length }
          .merge(Verification.verified('entity.erase', checks))
      end

      def select_entities(params)
        require_keys(params, %w[entity_ids replace], %w[entity_ids])
        entities = entities(params['entity_ids'])
        replace = params.key?('replace') ? boolean(params['replace'], 'replace') : true
        requested = entities.map { |item| persistent_id(item) }
        checks = []
        model.selection.clear if replace
        model.selection.add(entities)
        # Selection is not wrapped in an undo operation: SketchUp does not
        # commit selection changes as a model operation, and aborting one would
        # discard nothing while reporting a rollback that never happened.
        Verification.check_selection!('entity.select', checks, model, requested)
        {
          'selected_entity_ids' => model.selection.map { |item| persistent_id(item) },
          'selection_count' => model.selection.length
        }.merge(Verification.verified('entity.select', checks))
      end

      def validate_spec(params)
        require_keys(params, %w[spec], %w[spec])
        spec = params['spec']
        spec = JSON.parse(spec) if spec.is_a?(String)
        raise ArgumentError, 'spec must be an object' unless spec.is_a?(Hash)
        elements = spec['elements'] || spec['items']
        raise ArgumentError, 'spec must include elements' unless elements.is_a?(Array) && !elements.empty?

        results = elements.map { |element| compare_spec_element(element) }
        {
          'status' => aggregate_status(results.map { |item| item['status'] }),
          'unit' => DEFAULT_UNIT,
          'edited' => false,
          'elements' => results,
          'contacts' => contact_findings(results)
        }
      end

      def outliner(params)
        require_keys(params, [])
        nodes = hierarchy_nodes(model.entities, [])
        {
          'hierarchy' => nodes,
          'unit' => DEFAULT_UNIT,
          'scope' => 'outliner'
        }
      end

      def set_attribute(params)
        require_keys(params, %w[entity_id dictionary key value], %w[entity_id dictionary key value])
        item = entity(params['entity_id'])
        raise ArgumentError, 'entity does not support attribute dictionaries' unless item.respond_to?(:set_attribute)

        dictionary = non_empty_string(params['dictionary'], 'dictionary')
        raise ArgumentError, 'dictionary must be renco' unless dictionary == 'renco'

        key = non_empty_string(params['key'], 'key')
        value = attribute_value(params['value'])
        if key == 'type'
          existing = item.get_attribute('renco', 'type')
          if !existing.nil? && existing.to_s != value.to_s && !owner_approved?
            raise ArgumentError, 'renco/type is write-once without owner approval'
          end
        end
        checks = []
        with_operation('DCC-MCP Set Attribute') do
          item.set_attribute(dictionary, key, value)
          actual = item.get_attribute(dictionary, key)
          Verification.check!('attributes.set', checks, 'attribute_value', value, actual)
        end
        {
          'entity_id' => persistent_id(item),
          'dictionary' => dictionary,
          'key' => key,
          'value' => value
        }.merge(Verification.verified('attributes.set', checks))
      end

      def organize_categories(params)
        require_keys(params, [])
        before = geometry_snapshots
        checks = []
        created = []
        with_operation('DCC-MCP Category Folders') do
          CATEGORY_TAGS.each do |name, code|
            folder = find_folder(name) || model.layers.add_folder(name)
            tag = find_tag(code, false) || model.layers.add(code)
            raise ArgumentError, 'tag does not support folders' unless tag.respond_to?(:folder=)

            tag.folder = folder
            Verification.check!(
              'organize.categories', checks, "tag_folder_#{name}", name,
              tag.folder ? tag.folder.name.to_s : nil
            )
            created << { 'folder' => name, 'tag' => code }
          end
          assert_geometry_unmoved!('organize.categories', checks, before)
        end
        {
          'categories' => created,
          'unit' => DEFAULT_UNIT,
          'geometry_moved' => false
        }.merge(Verification.verified('organize.categories', checks))
      end

      # Non-root entities are refused before anything moves. The LEVEL /
      # 00_REFERENCE..05 hierarchy is the manual modelling standard; this
      # command does not build it.
      def organize_rooms(params)
        require_keys(params, %w[rooms], %w[rooms])
        rooms = params['rooms']
        raise ArgumentError, 'rooms must be a non-empty array' unless rooms.is_a?(Array) && !rooms.empty?

        membership = Hash.new { |table, key| table[key] = [] }
        rooms.each do |room|
          raise ArgumentError, 'room must be an object' unless room.is_a?(Hash)

          name = non_empty_string(room['name'], 'name')
          entity_id_array(room['entity_ids']).each do |identifier|
            membership[identifier] << name unless membership[identifier].include?(name)
          end
        end
        before = {}
        membership.each_key do |identifier|
          item = entity(identifier)
          unless model.entities.to_a.include?(item)
            raise ArgumentError, 'organize.rooms BLOCKs non-root entities; nested parents are not regrouped'
          end
          before[identifier] = bounds_snapshot(item)
        end
        checks = []
        grouped = []
        shared = []
        with_operation('DCC-MCP Organize Rooms') do
          exclusive = membership.select { |_identifier, names| names.length == 1 }
          shared_ids = membership.select { |_identifier, names| names.length > 1 }
          exclusive.group_by { |_identifier, names| names.first }.each do |room_name, pairs|
            identifiers = pairs.map(&:first)
            ents = identifiers.map { |identifier| entity(identifier) }
            parent = parent_entities_for(ents)
            group = parent.add_group(ents)
            group.name = room_name
            grouped << { 'room' => room_name, 'entity_ids' => identifiers }
          end
          shared_ids.each do |identifier, names|
            item = entity(identifier)
            raise ArgumentError, 'entity does not support attribute dictionaries' unless item.respond_to?(:set_attribute)

            item.set_attribute('renco', 'rooms', names)
            # Logged under every room. The geometry stays where it is and is not split.
            names.each do |room_name|
              shared << { 'room' => room_name, 'entity_id' => identifier, 'rooms' => names, 'split' => false }
            end
          end
          # add_group(existing) can invalidate the references captured above,
          # so the after-check looks the entities up again by persistent id.
          membership.each_key do |identifier|
            Verification.check!(
              'organize.rooms', checks, "bounds_unchanged_#{identifier}",
              before[identifier], bounds_snapshot(entity(identifier))
            )
          end
        end
        {
          'grouped' => grouped,
          'shared' => shared,
          'unit' => DEFAULT_UNIT,
          'geometry_moved' => false
        }.merge(Verification.verified('organize.rooms', checks))
      end

      def list_scenes(params)
        require_keys(params, [])
        values = model.pages.map { |page| scene_summary(page) }
        { 'scenes' => values, 'total' => values.length }
      end

      def create_scene(params)
        require_keys(params, %w[name description include_in_animation], %w[name])
        name = non_empty_string(params['name'], 'name')
        raise ArgumentError, "scene already exists: #{name}" if find_scene(name, false)

        created = nil
        checks = []
        expected_description = params['description'].to_s if params.key?('description')
        with_operation('DCC-MCP Create Scene') do
          created = model.pages.add(name)
          created.description = params['description'].to_s if params.key?('description')
          if params.key?('include_in_animation') && created.respond_to?(:include_in_animation=)
            created.include_in_animation = boolean(params['include_in_animation'], 'include_in_animation')
          end
          Verification.check_scene!('scenes.create', checks, model, name, expected_description)
        end
        { 'scene' => scene_summary(created) }
          .merge(Verification.verified('scenes.create', checks))
      end

      def update_scene(params)
        require_keys(
          params,
          %w[name new_name description include_in_animation capture_current_view],
          %w[name]
        )
        page = find_scene(params['name'])
        expected_name = params.key?('new_name') ? non_empty_string(params['new_name'], 'new_name') : page.name.to_s
        expected_description = params['description'].to_s if params.key?('description')
        checks = []
        with_operation('DCC-MCP Update Scene') do
          if params.key?('new_name')
            new_name = non_empty_string(params['new_name'], 'new_name')
            existing = find_scene(new_name, false)
            raise ArgumentError, "scene already exists: #{new_name}" if existing && existing != page

            page.name = new_name
          end
          page.description = params['description'].to_s if params.key?('description')
          if params.key?('include_in_animation') && page.respond_to?(:include_in_animation=)
            page.include_in_animation = boolean(params['include_in_animation'], 'include_in_animation')
          end
          if params.key?('capture_current_view') && boolean(params['capture_current_view'], 'capture_current_view')
            raise "SketchUp could not update scene: #{page.name}" unless page.update(PAGE_USE_ALL)
          end
          Verification.check_scene!('scenes.update', checks, model, expected_name, expected_description)
        end
        { 'scene' => scene_summary(page) }
          .merge(Verification.verified('scenes.update', checks))
      end

      def remove_scene(params)
        require_owner_approval!('scenes.remove')
        require_keys(params, %w[name], %w[name])
        page = find_scene(params['name'])
        name = page.name.to_s
        checks = []
        with_operation('DCC-MCP Remove Scene') do
          raise "SketchUp could not remove scene: #{name}" unless model.pages.erase(page)

          Verification.check_scene_absent!('scenes.remove', checks, model, name)
        end
        { 'removed_scene' => name }
          .merge(Verification.verified('scenes.remove', checks))
      end

      def list_tags(params)
        require_keys(params, [])
        values = model.layers.map { |layer| tag_summary(layer) }
        { 'tags' => values, 'total' => values.length, 'active_tag' => model.active_layer.name.to_s }
      end

      def create_tag(params)
        require_keys(params, %w[name visible], %w[name])
        name = non_empty_string(params['name'], 'name')
        raise ArgumentError, "tag already exists: #{name}" if find_tag(name, false)

        created = nil
        checks = []
        expected_visible = boolean(params['visible'], 'visible') if params.key?('visible')
        with_operation('DCC-MCP Create Tag') do
          created = model.layers.add(name)
          created.visible = boolean(params['visible'], 'visible') if params.key?('visible')
          Verification.check_tag!('tags.create', checks, model, name, expected_visible)
        end
        { 'tag' => tag_summary(created) }
          .merge(Verification.verified('tags.create', checks))
      end

      def assign_tag(params)
        require_keys(params, %w[entity_id tag], %w[entity_id tag])
        item = entity(params['entity_id'])
        if %w[Face Edge].include?(item.typename.to_s)
          raise ArgumentError, 'tags.assign refuses a raw Face or Edge'
        end
        tag = find_tag(params['tag'])
        raise ArgumentError, 'entity does not support tags' unless item.respond_to?(:layer=)

        checks = []
        with_operation('DCC-MCP Assign Tag') do
          item.layer = tag
          Verification.check_assigned_tag!('tags.assign', checks, item, tag)
        end
        { 'entity' => entity_summary(item), 'tag' => tag_summary(tag) }
          .merge(Verification.verified('tags.assign', checks))
      end

      def remove_tag(params)
        require_owner_approval!('tags.remove')
        require_keys(params, %w[name], %w[name])
        tag = find_tag(params['name'])
        raise ArgumentError, 'the default Untagged tag cannot be removed' if tag == model.layers[0]
        raise ArgumentError, "tag is in use: #{tag.name}" if tag_in_use?(tag)

        name = tag.name.to_s
        checks = []
        with_operation('DCC-MCP Remove Tag') do
          raise "SketchUp could not remove tag: #{name}" unless model.layers.remove(tag)

          Verification.check_tag_absent!('tags.remove', checks, model, name)
        end
        { 'removed_tag' => name }
          .merge(Verification.verified('tags.remove', checks))
      end

      def model
        Sketchup.active_model || raise('No active SketchUp model')
      end

      def with_operation(name)
        started = model.start_operation(name, true)
        raise "SketchUp could not start operation: #{name}" unless started

        result = yield
        raise "SketchUp could not commit operation: #{name}" unless model.commit_operation

        started = false
        result
      rescue StandardError
        model.abort_operation if started
        raise
      end

      def entity(value)
        id = integer(value, 'entity_id', 1)
        found = model.find_entity_by_persistent_id(id)
        found = found.first if found.is_a?(Array)
        raise ArgumentError, "entity was not found: #{id}" unless found&.valid?

        found
      end

      def entities(values)
        entity_id_array(values).map { |value| entity(value) }
      end

      def root_entity(value)
        found = entity(value)
        raise ArgumentError, 'entity must be in the model root context' unless model.entities.to_a.include?(found)

        found
      end

      def root_entities(values)
        entity_id_array(values).map { |value| root_entity(value) }
      end

      def entity_summary(item)
        summary = {
          'persistent_id' => persistent_id(item),
          'entity_id' => item.entityID,
          'type' => item.typename.to_s,
          'valid' => item.valid?,
          'hidden' => item.respond_to?(:hidden?) ? item.hidden? : false,
          'locked' => item.respond_to?(:locked?) ? item.locked? : false
        }
        summary['name'] = item.name.to_s if item.respond_to?(:name)
        summary['tag'] = item.layer.name.to_s if item.respond_to?(:layer) && item.layer
        if item.respond_to?(:material)
          summary['material'] = item.material ? item.material.display_name.to_s : nil
        end
        summary['bounds'] = bounds_summary(item.bounds) if item.respond_to?(:bounds)
        summary
      end

      def persistent_id(item)
        raise 'entity does not expose a persistent id' unless item.respond_to?(:persistent_id)

        item.persistent_id
      end

      def bounds_summary(bounds)
        {
          'empty' => bounds.empty?,
          'min' => point_array(bounds.min),
          'max' => point_array(bounds.max),
          'width' => bounds.width.to_f,
          'height' => bounds.height.to_f,
          'depth' => bounds.depth.to_f,
          'unit' => 'inches'
        }
      end

      def scene_summary(page)
        {
          'name' => page.name.to_s,
          'description' => page.description.to_s,
          'include_in_animation' => page.respond_to?(:include_in_animation?) ? page.include_in_animation? : true,
          'delay_time' => page.respond_to?(:delay_time) ? page.delay_time.to_f : nil,
          'transition_time' => page.respond_to?(:transition_time) ? page.transition_time.to_f : nil
        }
      end

      def find_scene(value, required = true)
        name = non_empty_string(value, 'scene')
        found = model.pages.find { |page| page.name.to_s == name }
        raise ArgumentError, "scene was not found: #{name}" if required && !found

        found
      end

      def tag_summary(tag)
        {
          'name' => tag.name.to_s,
          'visible' => tag.visible?,
          'active' => tag == model.active_layer,
          'default' => tag == model.layers[0]
        }
      end

      def find_tag(value, required = true)
        name = non_empty_string(value, 'tag')
        found = model.layers.find { |tag| tag.name.to_s == name }
        raise ArgumentError, "tag was not found: #{name}" if required && !found

        found
      end

      def tag_in_use?(tag)
        each_drawing_element.any? { |item| item.respond_to?(:layer) && item.layer == tag }
      end

      def each_drawing_element
        values = []
        model.entities.each { |entity| values << entity }
        model.definitions.each do |definition|
          definition.entities.each { |entity| values << entity }
        end
        values
      end

      def probe_entry(entry)
        text = entry.to_s
        unless PROBE_ENTRY_PATTERN.match?(text)
          raise ArgumentError, "probe entry must be Owner#symbol or Owner.symbol: #{entry.inspect}"
        end

        owner_name, symbol = text.split(/#(?!.*#)|\.(?!.*\.)/)
        owner = resolve_probe_owner(owner_name)
        {
          'owner' => owner_name,
          'symbol' => symbol,
          'present' => probe_present?(owner, symbol)
        }
      end

      def resolve_probe_owner(owner_name)
        owner_name.to_s.split('::').reduce(Object) do |namespace, segment|
          return nil unless namespace.const_defined?(segment, false)

          namespace.const_get(segment, false)
        end
      rescue NameError
        nil
      end

      # A symbol is present when the owner answers to it either as an instance
      # method or as a singleton method. `#alpha=` style setters are instance
      # methods, `Sketchup.version` style accessors are singleton methods.
      def probe_present?(owner, symbol)
        return false if owner.nil?

        name = symbol.to_sym
        owner.instance_methods.include?(name) ||
          owner.private_instance_methods.include?(name) ||
          owner.respond_to?(name)
      rescue StandardError
        false
      end

      def require_keys(params, allowed, required = [])
        unexpected = params.keys - allowed
        raise ArgumentError, "Unexpected parameters: #{unexpected.sort.join(', ')}" unless unexpected.empty?

        missing = required - params.keys
        raise ArgumentError, "Missing required parameters: #{missing.sort.join(', ')}" unless missing.empty?
      end

      def non_empty_string(value, name)
        raise ArgumentError, "#{name} must be a string" unless value.is_a?(String)

        text = value.strip
        raise ArgumentError, "#{name} must be a non-empty string" if text.empty?

        text
      end

      def optional_string(value)
        return nil if value.nil?
        raise ArgumentError, 'value must be a string' unless value.is_a?(String)

        text = value.strip
        text.empty? ? nil : text
      end

      def boolean(value, name)
        raise ArgumentError, "#{name} must be a boolean" unless value == true || value == false

        value
      end

      def number(value, name, minimum = nil, maximum = nil)
        raise ArgumentError, "#{name} must be numeric" unless value.is_a?(Numeric) && !value.is_a?(Complex)

        result = value.to_f
        raise ArgumentError, "#{name} must be finite" unless result.finite?
        raise ArgumentError, "#{name} must be at least #{minimum}" if minimum && result < minimum
        raise ArgumentError, "#{name} must be at most #{maximum}" if maximum && result > maximum

        result
      end

      def integer(value, name, minimum = nil, maximum = nil)
        raise ArgumentError, "#{name} must be an integer" unless value.is_a?(Integer)
        raise ArgumentError, "#{name} must be at least #{minimum}" if minimum && value < minimum
        raise ArgumentError, "#{name} must be at most #{maximum}" if maximum && value > maximum

        value
      end

      def non_empty_array(value, name)
        raise ArgumentError, "#{name} must be a non-empty array" unless value.is_a?(Array) && !value.empty?

        value
      end

      def entity_id_array(value)
        values = non_empty_array(value, 'entity_ids')
        raise ArgumentError, 'entity_ids must contain at most 500 values' if values.length > 500

        ids = values.map { |item| integer(item, 'entity_ids', 1) }
        raise ArgumentError, 'entity_ids must be unique' unless ids.uniq.length == ids.length

        ids
      end

      def numeric_triplet(value, name)
        raise ArgumentError, "#{name} must contain three numbers" unless value.is_a?(Array) && value.length == 3

        value.map { |item| number(item, name) }
      end

      def unit_name(value)
        name = value.to_s.downcase
        raise ArgumentError, "unit must be one of: #{UNIT_FACTORS.keys.join(', ')}" unless UNIT_FACTORS.key?(name)

        name
      end

      def positive_length(value, name, unit)
        number(value, name, 0.000_001) * UNIT_FACTORS.fetch(unit)
      end

      def point(value, name, unit)
        Geom::Point3d.new(*numeric_triplet(value, name).map { |item| item * UNIT_FACTORS.fetch(unit) })
      end

      def vector(value, name, unit)
        numeric_triplet(value, name).map { |item| item * UNIT_FACTORS.fetch(unit) }
      end

      def offset_point(origin, x, y, z)
        Geom::Point3d.new(origin.x + x, origin.y + y, origin.z + z)
      end

      def point_array(value)
        [value.x.to_f, value.y.to_f, value.z.to_f]
      end

      def current_model_path
        path = model.path.to_s
        path.empty? ? nil : File.expand_path(path)
      end

      def same_path?(left, right)
        return false if left.nil? || right.nil?
        return File.identical?(left, right) if File.exist?(left) && File.exist?(right)

        File::ALT_SEPARATOR == '\\' ? left.casecmp?(right) : left == right
      rescue SystemCallError
        File::ALT_SEPARATOR == '\\' ? left.casecmp?(right) : left == right
      end

      def input_file(value, name, extensions)
        path = absolute_path(value, name)
        raise ArgumentError, "#{name} must be an existing file" unless File.file?(path)

        validate_extension(path, name, extensions)
      end

      def output_file(value, name, extensions)
        path = absolute_path(value, name)
        raise ArgumentError, "#{name} parent directory does not exist" unless File.directory?(File.dirname(path))

        validate_extension(path, name, extensions)
      end

      def absolute_path(value, name)
        text = non_empty_string(value, name)
        raise ArgumentError, "#{name} must be an absolute path" unless Pathname.new(text).absolute?

        File.expand_path(text)
      end

      def validate_extension(path, name, extensions)
        extension = File.extname(path).downcase
        unless extensions.include?(extension)
          raise ArgumentError, "#{name} must use one of: #{extensions.sort.join(', ')}"
        end

        path
      end

      def versioned_project_file(value)
        path = require_project_path(output_file(value, 'path', ['.skp']), 'path')
        parsed = parse_model_name(File.basename(path))
        unless parsed
          raise ArgumentError, 'path must be <JobID>_<Project>_Model_v<NN>.skp'
        end

        source = current_model_path
        if source.nil? || source.empty?
          raise ArgumentError, 'save_copy needs a named source model'
        end

        source_parsed = parse_model_name(File.basename(source))
        unless source_parsed
          raise ArgumentError, 'source model name must be <JobID>_<Project>_Model_v<NN>.skp'
        end
        unless parsed[:job] == source_parsed[:job] && parsed[:project] == source_parsed[:project]
          raise ArgumentError, 'save_copy base name must match the source model'
        end
        unless parsed[:version] > source_parsed[:version]
          raise ArgumentError, 'save_copy version must be strictly higher than the source'
        end

        path
      end

      def parse_model_name(base)
        match = MODEL_FILE_NAME.match(base.to_s)
        return nil unless match

        { job: match[1], project: match[2], version: match[3].to_i }
      end

      def project_root
        raw = ENV.fetch(PROJECT_FOLDER_ENV, '').to_s.strip
        if raw.empty?
          raise ArgumentError, "project folder is not configured; set #{PROJECT_FOLDER_ENV}"
        end

        root = File.expand_path(raw)
        raise ArgumentError, "project folder does not exist: #{root}" unless File.directory?(root)

        File.realpath(root)
      end

      def require_project_path(path, name)
        root = project_root
        candidate = File.expand_path(path)
        if symlink_path?(candidate)
          raise ArgumentError, "#{name} is a symlink; refusing: #{candidate}"
        end
        if path_exists?(candidate)
          real = File.realpath(candidate)
          unless path_inside?(real, root)
            raise ArgumentError, "#{name} is outside the project folder: #{candidate}"
          end
        end
        parent = File.dirname(candidate)
        real_parent = path_exists?(parent) ? File.realpath(parent) : parent
        unless path_inside?(real_parent, root)
          raise ArgumentError, "#{name} is outside the project folder: #{candidate}"
        end

        candidate
      end

      def symlink_path?(path)
        File.lstat(path).symlink?
      rescue Errno::ENOENT, SystemCallError
        false
      end

      def path_exists?(path)
        File.lstat(path)
        true
      rescue Errno::ENOENT
        false
      end

      def owner_approved?
        ENV.fetch(OWNER_APPROVAL_ENV, '').to_s == '1'
      end

      def require_owner_approval!(action)
        return if owner_approved?

        raise ArgumentError, "#{action} requires owner approval; set #{OWNER_APPROVAL_ENV}=1"
      end

      def with_length_unit(result)
        return result unless result.is_a?(Hash)
        return result if result.key?('unit')
        return result unless contains_length?(result)

        result.merge('unit' => DEFAULT_UNIT)
      end

      def contains_length?(value)
        case value
        when Hash
          value.any? { |key, item| LENGTH_RESULT_KEYS.include?(key.to_s) || contains_length?(item) }
        when Array
          value.any? { |item| contains_length?(item) }
        else
          false
        end
      end

      def path_inside?(path, root)
        return false if path.nil? || root.nil?
        prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
        if File::ALT_SEPARATOR == '\\'
          path.casecmp(root).zero? || path.downcase.start_with?(prefix.downcase)
        else
          path == root || path.start_with?(prefix)
        end
      end

      def compare_spec_element(element)
        raise ArgumentError, 'element must be an object' unless element.is_a?(Hash)

        identifier = integer(element['id'], 'id', 1)
        type_name = non_empty_string(element['type'], 'type').downcase
        unless (DRAWING_KINDS + PRODUCT_KINDS).include?(type_name)
          raise ArgumentError, 'type must be wall, opening, appliance, product, or package'
        end
        if element.key?('unit') && element['unit'].to_s.downcase != DEFAULT_UNIT
          raise ArgumentError, 'validate_spec lengths must be inches'
        end

        tolerance = DRAWING_KINDS.include?(type_name) ? WALL_TOLERANCE_INCHES : PRODUCT_TOLERANCE_INCHES
        missing_axes = SPEC_AXES.reject { |axis| element.key?(axis) }
        unless missing_axes.empty?
          return cannot_verify(
            identifier, type_name, tolerance,
            "missing axes: #{missing_axes.join(', ')}",
            missing_axes
          )
        end

        specified = {}
        SPEC_AXES.each { |axis| specified[axis] = number(element[axis], axis) }
        found = model.find_entity_by_persistent_id(identifier)
        found = found.first if found.is_a?(Array)
        missing = found.nil? || (found.respond_to?(:valid?) && !found.valid?)
        if missing
          return {
            'id' => identifier,
            'type' => type_name,
            'status' => 'BLOCK',
            'unit' => DEFAULT_UNIT,
            'tolerance_inches' => tolerance,
            'specified' => specified.merge('type' => type_name),
            'available' => nil,
            'delta' => nil,
            'reason' => 'entity was not found'
          }
        end

        problem = placement_problem(found)
        unless problem.nil?
          return cannot_verify(identifier, type_name, tolerance, problem, [], specified)
        end

        available = available_geometry(found)
        delta = {}
        SPEC_AXES.each { |axis| delta[axis] = available[axis] - specified[axis] }
        outside = SPEC_AXES.any? { |axis| (delta[axis].abs - tolerance) > COMPARE_EPSILON_INCHES }
        recorded = recorded_type(found)
        status = if outside
                   'BLOCK'
                 elsif !recorded.nil? && recorded != type_name
                   'MISMATCH'
                 else
                   'MATCH'
                 end
        {
          'id' => identifier,
          'type' => type_name,
          'status' => status,
          'unit' => DEFAULT_UNIT,
          'tolerance_inches' => tolerance,
          'specified' => specified.merge('type' => type_name),
          'available' => available.merge('type' => recorded),
          'delta' => delta
        }
      end

      def cannot_verify(identifier, type_name, tolerance, reason, missing_axes, specified = {})
        {
          'id' => identifier,
          'type' => type_name,
          'status' => 'CANNOT VERIFY',
          'unit' => DEFAULT_UNIT,
          'tolerance_inches' => tolerance,
          'specified' => specified.merge('type' => type_name),
          'available' => nil,
          'delta' => nil,
          'missing_axes' => missing_axes,
          'reason' => reason
        }
      end

      def placement_problem(item)
        return 'entity is nested' unless model.entities.to_a.include?(item)
        return nil unless item.respond_to?(:transformation)

        transformation = item.transformation
        return nil if transformation.nil?
        return 'entity is rotated' unless world_aligned?(transformation)

        nil
      end

      def world_aligned?(transformation)
        return true unless transformation.respond_to?(:xaxis)

        [transformation.xaxis, transformation.yaxis, transformation.zaxis].all? do |axis|
          axis_aligned_vector?(axis)
        end
      end

      def axis_aligned_vector?(axis)
        return false unless axis.respond_to?(:x) && axis.respond_to?(:y) && axis.respond_to?(:z)

        components = [axis.x.to_f, axis.y.to_f, axis.z.to_f]
        components.count { |value| value.abs > COMPARE_EPSILON_INCHES } == 1
      end

      def aggregate_status(statuses)
        return 'BLOCK' if statuses.include?('BLOCK')
        return 'MISMATCH' if statuses.include?('MISMATCH')
        return 'CANNOT VERIFY' if statuses.include?('CANNOT VERIFY')

        'MATCH'
      end

      def contact_findings(results)
        usable = results.select { |item| item['available'].is_a?(Hash) && item['status'] != 'CANNOT VERIFY' }
        findings = []
        usable.each_with_index do |left, index|
          usable[(index + 1)..-1].each do |right|
            findings << classify_contact(left, right)
          end
        end
        findings
      end

      def classify_contact(left, right)
        gap = axis_gaps(left['available'], right['available'])
        positive = gap.values.any? { |value| value > COMPARE_EPSILON_INCHES }
        negative = gap.values.count { |value| value < -COMPARE_EPSILON_INCHES }
        relation = if positive
                     'gap'
                   elsif negative == 3
                     'overlap'
                   else
                     'contact'
                   end
        {
          'left_id' => left['id'],
          'right_id' => right['id'],
          'relation' => relation,
          'gap_inches' => gap,
          'edited' => false
        }
      end

      def axis_gaps(left, right)
        {
          'x' => edge_gap(left['x'], left['width'], right['x'], right['width']),
          'y' => edge_gap(left['y'], left['depth'], right['y'], right['depth']),
          'z' => edge_gap(left['z'], left['height'], right['z'], right['height'])
        }
      end

      def edge_gap(origin_a, size_a, origin_b, size_b)
        [origin_a - (origin_b + size_b), origin_b - (origin_a + size_a)].max
      end

      def available_geometry(item)
        bounds = item.bounds
        # width is X, depth is Y, height is Z. That is the same mapping add_box uses.
        # SketchUp names the Y extent "height" and the Z extent "depth".
        {
          'x' => bounds.min.x.to_f,
          'y' => bounds.min.y.to_f,
          'z' => bounds.min.z.to_f,
          'width' => bounds.width.to_f,
          'depth' => bounds.height.to_f,
          'height' => bounds.depth.to_f
        }
      end

      def recorded_type(item)
        return nil unless item.respond_to?(:get_attribute)

        value = item.get_attribute('renco', 'type')
        return nil if value.nil?

        text = value.to_s.strip.downcase
        text.empty? ? nil : text
      end

      def hierarchy_nodes(entities, path)
        return [] unless entities.respond_to?(:to_a)

        entities.to_a.map { |item| hierarchy_node(item, path) }
      end

      def hierarchy_node(item, path)
        name = item.respond_to?(:name) ? item.name.to_s : ''
        here = path + [name]
        children = nested_entities(item)
        node = {
          'persistent_id' => item.respond_to?(:persistent_id) ? item.persistent_id : nil,
          'entity_id' => item.respond_to?(:entityID) ? item.entityID : nil,
          'name' => name,
          'type' => item.typename.to_s,
          'path' => here,
          'attributes' => read_attributes(item),
          'unit' => DEFAULT_UNIT
        }
        node['bounds'] = bounds_summary(item.bounds) if item.respond_to?(:bounds)
        node['children'] = children ? hierarchy_nodes(children, here) : []
        node
      end

      def nested_entities(item)
        return item.entities if item.respond_to?(:entities)
        if item.respond_to?(:definition) && item.definition && item.definition.respond_to?(:entities)
          return item.definition.entities
        end

        nil
      end

      def read_attributes(item)
        if item.respond_to?(:attribute_dictionary_dump)
          return item.attribute_dictionary_dump
        end
        return {} unless item.respond_to?(:attribute_dictionaries) && item.attribute_dictionaries

        item.attribute_dictionaries.each_with_object({}) do |dictionary, copy|
          pairs = {}
          dictionary.each { |key, value| pairs[key.to_s] = value }
          copy[dictionary.name.to_s] = pairs
        end
      end

      def attribute_value(value)
        case value
        when String, Numeric, TrueClass, FalseClass
          value
        when Array
          unless value.all? { |item| item.is_a?(String) }
            raise ArgumentError, 'value arrays must contain only strings'
          end

          value
        else
          raise ArgumentError, 'value must be a string, number, boolean, or array of strings'
        end
      end

      def find_folder(name)
        layer_folders.find { |folder| folder.name.to_s == name }
      end

      def layer_folders
        layers = model.layers
        if layers.respond_to?(:folders)
          Array(layers.folders)
        elsif layers.respond_to?(:each_folder)
          values = []
          layers.each_folder { |folder| values << folder }
          values
        else
          raise ArgumentError, 'SketchUp build does not expose tag folders'
        end
      end

      def geometry_snapshots
        each_drawing_entity.each_with_object({}) do |item, shots|
          next unless item.respond_to?(:persistent_id) && item.respond_to?(:bounds)

          shots[item.persistent_id] = bounds_snapshot(item)
        end
      end

      def each_drawing_entity(entities = model.entities, acc = [])
        return acc unless entities.respond_to?(:to_a)

        entities.to_a.each do |item|
          acc << item
          nested = nested_entities(item)
          each_drawing_entity(nested, acc) if nested
        end
        acc
      end

      def bounds_snapshot(item)
        bounds = item.bounds
        {
          'min' => point_array(bounds.min),
          'max' => point_array(bounds.max),
          'width' => bounds.width.to_f,
          'height' => bounds.height.to_f,
          'depth' => bounds.depth.to_f
        }
      end

      def assert_geometry_unmoved!(tool, checks, before)
        before.each do |identifier, shot|
          current = entity(identifier)
          Verification.check!(tool, checks, "bounds_unchanged_#{identifier}", shot, bounds_snapshot(current))
        end
        return unless before.empty?

        Verification.check!(tool, checks, 'geometry_moved', false, false)
      end

      def parent_entities_for(entities)
        unless entities.all? { |item| model.entities.to_a.include?(item) }
          raise ArgumentError, 'room entities must be siblings in the model root'
        end

        model.entities
      end

      def symbol_keyed_options(value, name)
        raise ArgumentError, "#{name} must be an object" unless value.is_a?(Hash)
        raise ArgumentError, "#{name} must contain at most #{MAX_OPTION_KEYS} keys" if value.length > MAX_OPTION_KEYS
        raise ArgumentError, "#{name} keys must be strings" unless value.keys.all? { |key| key.is_a?(String) }

        value.each_with_object({}) do |(key, option_value), options|
          unless OPTION_KEY_PATTERN.match?(key)
            raise ArgumentError, "#{name} key must match #{OPTION_KEY_PATTERN.inspect}: #{key.inspect}"
          end

          options[key.to_sym] = option_value
        end
      end
    end
  end
end
