# Copyright (C) 2012-2016 Zammad Foundation, http://zammad-foundation.org/
module HasGroups
  extend ActiveSupport::Concern

  included do
    before_destroy :destroy_group_relations

    attr_accessor :group_access_buffer

    after_create  :check_group_access_buffer
    after_update  :check_group_access_buffer

    association_attributes_ignored :groups

    has_many group_through_identifier
    has_many :groups, through: group_through_identifier do

      # A helper to join the :through table into the result of groups to access :through attributes
      #
      # @param [String, Array<String>] access Limiting to one or more access verbs. 'full' gets added automatically
      #
      # @example All access groups
      #   user.groups.access
      #   #=> [#<Group id: 1, access="read", ...>, ...]
      #
      # @example Groups for given access(es) plus 'full'
      #   user.groups.access('read')
      #   #=> [#<Group id: 1, access="full", ...>, ...]
      #
      # @example Groups for given access(es)es plus 'full'
      #   user.groups.access('read', 'write')
      #   #=> [#<Group id: 1, access="full", ...>, ...]
      #
      # @return [ActiveRecord::AssociationRelation<[<Group]>] List of Groups with :through attributes
      def access(*access)
        table_name = proxy_association.owner.class.group_through.table_name
        query      = select("groups.*, #{table_name}.*")
        return query if access.blank?

        access.push('full') if !access.include?('full')

        query.where("#{table_name}.access" => access)
      end
    end
  end

  # Checks a given Group( ID) for given access(es) for the instance.
  # Checks indirect access via Roles if instance has Roles, too.
  #
  # @example Group ID param
  #   user.group_access?(1, 'read')
  #   #=> true
  #
  # @example Group param
  #   user.group_access?(group, 'read')
  #   #=> true
  #
  # @example Access list
  #   user.group_access?(group, ['read', 'create'])
  #   #=> true
  #
  # @return [Boolean]
  def group_access?(group_id, access)
    group_id = self.class.ensure_group_id_parameter(group_id)
    access   = self.class.ensure_group_access_list_parameter(access)

    # check direct access
    return true if group_through.klass.includes(:group).exists?(
      group_through.foreign_key => id,
      group_id: group_id,
      access:   access,
      groups:   {
        active: true
      }
    )

    # check indirect access through Roles if possible
    return false if !respond_to?(:role_access?)
    role_access?(group_id, access)
  end

  # Lists the Group IDs the instance has the given access(es) plus 'full' to.
  # Adds indirect accessable Group IDs via Roles if instance has Roles, too.
  #
  # @example Single access
  #   user.group_ids_access('read')
  #   #=> [1, 3, ...]
  #
  # @example Access list
  #   user.group_ids_access(['read', 'create'])
  #   #=> [1, 3, ...]
  #
  # @return [Array<Integer>] Group IDs the instance has the given access(es) to.
  def group_ids_access(access)
    access = self.class.ensure_group_access_list_parameter(access)

    foreign_key = group_through.foreign_key
    klass       = group_through.klass

    # check direct access
    ids   = klass.includes(:group).where(foreign_key => id, access: access, groups: { active: true }).pluck(:group_id)
    ids ||= []

    # check indirect access through roles if possible
    return ids if !respond_to?(:role_ids)

    role_group_ids = RoleGroup.includes(:group).where(role_id: role_ids, access: access, groups: { active: true }).pluck(:group_id)

    # combines and removes duplicates
    # and returns them in one statement
    ids | role_group_ids
  end

  # Lists Groups the instance has the given access(es) plus 'full' to.
  # Adds indirect accessable Groups via Roles if instance has Roles, too.
  #
  # @example Single access
  #   user.groups_access('read')
  #   #=> [#<Group id: 1, access="read", ...>, ...]
  #
  # @example Access list
  #   user.groups_access(['read', 'create'])
  #   #=> [#<Group id: 1, access="read", ...>, ...]
  #
  # @return [Array<Group>] Groups the instance has the given access(es) to.
  def groups_access(access)
    group_ids = group_ids_access(access)
    Group.where(id: group_ids)
  end

  # Returns a map of Group name to access
  #
  # @example
  #   user.group_names_access_map
  #   #=> {'Users' => 'full', 'Support' => ['read', 'write']}
  #
  # @return [Hash<String=>String,Array<String>>] The map of Group name to access
  def group_names_access_map
    groups_access_map(:name)
  end

  # Stores a map of Group ID to access. Deletes all other relations.
  #
  # @example
  #   user.group_names_access_map = {'Users' => 'full', 'Support' => ['read', 'write']}
  #   #=> {'Users' => 'full', 'Support' => ['read', 'write']}
  #
  # @return [Hash<String=>String,Array<String>>] The given map
  def group_names_access_map=(name_access_map)
    groups_access_map_store(name_access_map) do |group_name|
      Group.where(name: group_name).pluck(:id).first
    end
  end

  # Returns a map of Group ID to access
  #
  # @example
  #   user.group_ids_access_map
  #   #=> {1 => 'full', 42 => ['read', 'write']}
  #
  # @return [Hash<Integer=>String,Array<String>>] The map of Group ID to access
  def group_ids_access_map
    groups_access_map(:id)
  end

  # Stores a map of Group ID to access. Deletes all other relations.
  #
  # @example
  #   user.group_ids_access_map = {1 => 'full', 42 => ['read', 'write']}
  #   #=> {1 => 'full', 42 => ['read', 'write']}
  #
  # @return [Hash<Integer=>String,Array<String>>] The given map
  def group_ids_access_map=(id_access_map)
    groups_access_map_store(id_access_map)
  end

  # An alias to .groups class method
  def group_through
    @group_through ||= self.class.group_through
  end

  private

  def groups_access_map(key)
    {}.tap do |hash|
      groups.access.where(active: true).pluck(key, :access).each do |entry|
        hash[ entry[0] ] ||= []
        hash[ entry[0] ].push(entry[1])
      end
    end
  end

  def groups_access_map_store(map)
    map.each do |group_identifier, accesses|
      # use given key as identifier or look it up
      # via the given block which returns the identifier
      group_id = block_given? ? yield(group_identifier) : group_identifier

      if !accesses.is_a?(Array)
        accesses = [accesses]
      end

      accesses.each do |access|
        push_group_access_buffer(
          group_id: group_id,
          access:   access
        )

        Rails.logger.error "TE DEBUG group_access_buffer = #{group_access_buffer.inspect}"
      end
    end

    check_group_access_buffer if id
  end

  def push_group_access_buffer(entry)
    @group_access_buffer ||= []
    @group_access_buffer.push(entry)
  end

  def check_group_access_buffer
    return if group_access_buffer.blank?
    destroy_group_relations

    foreign_key = group_through.foreign_key
    entries     = group_access_buffer.collect do |entry|
      entry[foreign_key] = id
      entry
    end

    group_through.klass.create!(entries)

    group_access_buffer = nil

    cache_delete
    true
  end

  def destroy_group_relations
    group_through.klass.destroy_all(group_through.foreign_key => id)
  end

  # methods defined here are going to extend the class, not the instance of it
  class_methods do

    # Lists IDs of instances having the given access(es) to the given Group.
    #
    # @example Group ID param
    #   User.group_access_ids(1, 'read')
    #   #=> [1, 3, ...]
    #
    # @example Group param
    #   User.group_access_ids(group, 'read')
    #   #=> [1, 3, ...]
    #
    # @example Access list
    #   User.group_access_ids(group, ['read', 'create'])
    #   #=> [1, 3, ...]
    #
    # @return [Array<Integer>]
    def group_access_ids(group_id, access)
      group_id = ensure_group_id_parameter(group_id)
      access   = ensure_group_access_list_parameter(access)

      # check direct access
      ids   = group_through.klass.includes(name.downcase).where(group_id: group_id, access: access, table_name => { active: true }).pluck(group_through.foreign_key)
      ids ||= []

      # check indirect access through roles if possible
      return ids if !respond_to?(:role_access_ids)
      role_instance_ids = role_access_ids(group_id, access)

      # combines and removes duplicates
      # and returns them in one statement
      ids | role_instance_ids
    end

    # Lists instances having the given access(es) to the given Group.
    #
    # @example Group ID param
    #   User.group_access(1, 'read')
    #   #=> [#<User id: 1, ...>, ...]
    #
    # @example Group param
    #   User.group_access(group, 'read')
    #   #=> [#<User id: 1, ...>, ...]
    #
    # @example Access list
    #   User.group_access(group, ['read', 'create'])
    #   #=> [#<User id: 1, ...>, ...]
    #
    # @return [Array<Class>]
    def group_access(group_id, access)
      instance_ids = group_access_ids(group_id, access)
      where(id: instance_ids)
    end

    # The reflection instance containing the association data
    #
    # @example
    #   User.group_through
    #   #=> <ActiveRecord::Reflection::HasManyReflection:0x007fd2f5785440 @name=:user_groups, ...>
    #
    # @return [ActiveRecord::Reflection::HasManyReflection] The given map
    def group_through
      @group_through ||= reflect_on_association(group_through_identifier)
    end

    # The identifier of the has_many :through relation
    #
    # @example
    #   User.group_through_identifier
    #   #=> :user_groups
    #
    # @return [Symbol] The relation identifier
    def group_through_identifier
      "#{name.downcase}_groups".to_sym
    end

    def ensure_group_id_parameter(group_or_id)
      return group_or_id if group_or_id.is_a?(Integer)
      group_or_id.id
    end

    def ensure_group_access_list_parameter(access)
      access = [access] if access.is_a?(String)
      access.push('full') if !access.include?('full')
      access
    end
  end
end
