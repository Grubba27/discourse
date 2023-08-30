# frozen_string_literal: true

if ARGV.include?("bbcode-to-md")
  # Replace (most) bbcode with markdown before creating posts.
  # This will dramatically clean up the final posts in Discourse.
  #
  # In a temp dir:
  #
  # git clone https://github.com/nlalonde/ruby-bbcode-to-md.git
  # cd ruby-bbcode-to-md
  # gem build ruby-bbcode-to-md.gemspec
  # gem install ruby-bbcode-to-md-*.gem
  require "ruby-bbcode-to-md"
end

require "pg"
require "set"
require "redcarpet"
require "htmlentities"

puts "Loading application..."
require_relative "../../config/environment"
require_relative "../import_scripts/base/uploader"

module BulkImport
end

class BulkImport::Base
  NOW ||= "now()"
  PRIVATE_OFFSET ||= 2**30

  # rubocop:disable Layout/HashAlignment

  CHARSET_MAP = {
    "armscii8" => nil,
    "ascii" => Encoding::US_ASCII,
    "big5" => Encoding::Big5,
    "binary" => Encoding::ASCII_8BIT,
    "cp1250" => Encoding::Windows_1250,
    "cp1251" => Encoding::Windows_1251,
    "cp1256" => Encoding::Windows_1256,
    "cp1257" => Encoding::Windows_1257,
    "cp850" => Encoding::CP850,
    "cp852" => Encoding::CP852,
    "cp866" => Encoding::IBM866,
    "cp932" => Encoding::Windows_31J,
    "dec8" => nil,
    "eucjpms" => Encoding::EucJP_ms,
    "euckr" => Encoding::EUC_KR,
    "gb2312" => Encoding::EUC_CN,
    "gbk" => Encoding::GBK,
    "geostd8" => nil,
    "greek" => Encoding::ISO_8859_7,
    "hebrew" => Encoding::ISO_8859_8,
    "hp8" => nil,
    "keybcs2" => nil,
    "koi8r" => Encoding::KOI8_R,
    "koi8u" => Encoding::KOI8_U,
    "latin1" => Encoding::ISO_8859_1,
    "latin2" => Encoding::ISO_8859_2,
    "latin5" => Encoding::ISO_8859_9,
    "latin7" => Encoding::ISO_8859_13,
    "macce" => Encoding::MacCentEuro,
    "macroman" => Encoding::MacRoman,
    "sjis" => Encoding::SHIFT_JIS,
    "swe7" => nil,
    "tis620" => Encoding::TIS_620,
    "ucs2" => Encoding::UTF_16BE,
    "ujis" => Encoding::EucJP_ms,
    "utf8" => Encoding::UTF_8,
  }

  # rubocop:enable Layout/HashAlignment

  def initialize
    charset = ENV["DB_CHARSET"] || "utf8"
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    @encoder = PG::TextEncoder::CopyRow.new
    @raw_connection = PG.connect(dbname: db[:database], port: db[:port])
    @uploader = ImportScripts::Uploader.new
    @html_entities = HTMLEntities.new
    @encoding = CHARSET_MAP[charset]
    @bbcode_to_md = true if use_bbcode_to_md?

    @markdown =
      Redcarpet::Markdown.new(
        Redcarpet::Render::HTML.new(hard_wrap: true),
        no_intra_emphasis: true,
        fenced_code_blocks: true,
        autolink: true,
      )
  end

  def run
    start_time = Time.now

    puts "Starting..."
    Rails.logger.level = 3 # :error, so that we don't create log files that are many GB
    preload_i18n
    create_migration_mappings_table
    fix_highest_post_numbers
    load_imported_ids
    load_indexes
    execute
    fix_primary_keys
    execute_after
    puts "Done! (#{((Time.now - start_time) / 60).to_i} minutes)"
    puts "Now run the 'import:ensure_consistency' rake task."
  end

  def preload_i18n
    puts "Preloading I18n..."
    I18n.locale = ENV.fetch("LOCALE") { SiteSettings::DefaultsProvider::DEFAULT_LOCALE }.to_sym
    I18n.t("test")
    ActiveSupport::Inflector.transliterate("test")
  end

  MAPPING_TYPES = Enum.new(upload: 1)

  def create_migration_mappings_table
    puts "Creating migration mappings table..."
    @raw_connection.exec <<~SQL
      CREATE TABLE IF NOT EXISTS migration_mappings (
        original_id VARCHAR(255) NOT NULL,
        type INTEGER NOT NULL,
        discourse_id VARCHAR(255) NOT NULL,
        PRIMARY KEY (original_id, type)
      )
    SQL
  end

  def fix_highest_post_numbers
    puts "Fixing highest post numbers..."
    @raw_connection.exec <<-SQL
      WITH X AS (
          SELECT topic_id
               , COALESCE(MAX(post_number), 0) max_post_number
            FROM posts
           WHERE deleted_at IS NULL
        GROUP BY topic_id
      )
      UPDATE topics
         SET highest_post_number = X.max_post_number
        FROM X
       WHERE id = X.topic_id
         AND highest_post_number <> X.max_post_number
    SQL
  end

  def imported_ids(name)
    map = {}
    ids = []

    @raw_connection.send_query(
      "SELECT value, #{name}_id FROM #{name}_custom_fields WHERE name = 'import_id'",
    )
    @raw_connection.set_single_row_mode

    @raw_connection.get_result.stream_each do |row|
      id = row["value"].to_i
      ids << id
      map[id] = row["#{name}_id"].to_i
    end

    @raw_connection.get_result

    [map, ids]
  end

  def load_imported_ids
    puts "Loading imported group ids..."
    @groups, imported_group_ids = imported_ids("group")
    @last_imported_group_id = imported_group_ids.max || -1

    puts "Loading imported user ids..."
    @users, imported_user_ids = imported_ids("user")
    @last_imported_user_id = imported_user_ids.max || -1

    puts "Loading imported category ids..."
    @categories, imported_category_ids = imported_ids("category")
    @last_imported_category_id = imported_category_ids.max || -1

    puts "Loading imported topic ids..."
    @topics, imported_topic_ids = imported_ids("topic")
    @last_imported_topic_id = imported_topic_ids.select { |id| id < PRIVATE_OFFSET }.max || -1
    @last_imported_private_topic_id =
      imported_topic_ids.select { |id| id > PRIVATE_OFFSET }.max || (PRIVATE_OFFSET - 1)

    puts "Loading imported post ids..."
    @posts, imported_post_ids = imported_ids("post")
    @last_imported_post_id = imported_post_ids.select { |id| id < PRIVATE_OFFSET }.max || -1
    @last_imported_private_post_id =
      imported_post_ids.select { |id| id > PRIVATE_OFFSET }.max || (PRIVATE_OFFSET - 1)
  end

  def last_id(klass)
    # the first record created will have id of this value + 1
    [klass.unscoped.maximum(:id) || 0, 0].max
  end

  def load_values(name, column, size)
    map = Array.new(size)

    @raw_connection.send_query("SELECT id, #{column} FROM #{name}")
    @raw_connection.set_single_row_mode

    @raw_connection.get_result.stream_each { |row| map[row["id"].to_i] = row[column].to_i }

    @raw_connection.get_result

    map
  end

  def load_index(type)
    map = {}

    @raw_connection.send_query(
      "SELECT original_id, discourse_id FROM migration_mappings WHERE type = #{type}",
    )
    @raw_connection.set_single_row_mode

    @raw_connection.get_result.stream_each { |row| map[row["original_id"]] = row["discourse_id"] }

    @raw_connection.get_result

    map
  end

  def load_indexes
    puts "Loading groups indexes..."
    @last_group_id = last_id(Group)
    group_names = Group.unscoped.pluck(:name).map(&:downcase).to_set

    puts "Loading users indexes..."
    @last_user_id = last_id(User)
    @last_user_email_id = last_id(UserEmail)
    @last_sso_record_id = last_id(SingleSignOnRecord)
    @emails = UserEmail.pluck(:email, :user_id).to_h
    @external_ids = SingleSignOnRecord.pluck(:external_id, :user_id).to_h
    @usernames_and_groupnames_lower = User.unscoped.pluck(:username_lower).to_set.merge(group_names)
    @anonymized_user_suffixes =
      DB.query_single(
        "SELECT SUBSTRING(username_lower, 5)::BIGINT FROM users WHERE username_lower ~* '^anon\\d+$'",
      ).to_set
    @mapped_usernames =
      UserCustomField
        .joins(:user)
        .where(name: "import_username")
        .pluck("user_custom_fields.value", "users.username")
        .to_h
    @last_muted_user_id = last_id(MutedUser)
    @last_user_history_id = last_id(UserHistory)
    @last_user_avatar_id = last_id(UserAvatar)
    @last_upload_id = last_id(Upload)

    puts "Loading categories indexes..."
    @last_category_id = last_id(Category)
    @last_category_group_id = last_id(CategoryGroup)
    @highest_category_position = Category.unscoped.maximum(:position) || 0
    @category_names =
      Category
        .unscoped
        .pluck(:parent_category_id, :name)
        .map { |pci, name| "#{pci}-#{name.downcase}" }
        .to_set

    puts "Loading topics indexes..."
    @last_topic_id = last_id(Topic)
    @highest_post_number_by_topic_id = load_values("topics", "highest_post_number", @last_topic_id)

    puts "Loading posts indexes..."
    @last_post_id = last_id(Post)
    @post_number_by_post_id = load_values("posts", "post_number", @last_post_id)
    @topic_id_by_post_id = load_values("posts", "topic_id", @last_post_id)

    puts "Loading post actions indexes..."
    @last_post_action_id = last_id(PostAction)

    puts "Loading upload indexes..."
    @uploads_mapping = load_index(MAPPING_TYPES[:upload])
    @uploads_by_sha1 = Upload.pluck(:sha1, :id).to_h
  end

  def use_bbcode_to_md?
    ARGV.include?("bbcode-to-md")
  end

  def execute
    raise NotImplementedError
  end

  def execute_after
  end

  def fix_primary_keys
    puts "Updating primary key sequences..."
    if @last_group_id > 0
      @raw_connection.exec("SELECT setval('#{Group.sequence_name}', #{@last_group_id})")
    end
    if @last_user_id > 0
      @raw_connection.exec("SELECT setval('#{User.sequence_name}', #{@last_user_id})")
    end
    if @last_user_email_id > 0
      @raw_connection.exec("SELECT setval('#{UserEmail.sequence_name}', #{@last_user_email_id})")
    end
    if @last_sso_record_id > 0
      @raw_connection.exec(
        "SELECT setval('#{SingleSignOnRecord.sequence_name}', #{@last_sso_record_id})",
      )
    end
    if @last_category_id > 0
      @raw_connection.exec("SELECT setval('#{Category.sequence_name}', #{@last_category_id})")
    end
    if @last_category_group_id > 0
      @raw_connection.exec(
        "SELECT setval('#{CategoryGroup.sequence_name}', #{@last_category_group_id})",
      )
    end
    if @last_topic_id > 0
      @raw_connection.exec("SELECT setval('#{Topic.sequence_name}', #{@last_topic_id})")
    end
    if @last_post_id > 0
      @raw_connection.exec("SELECT setval('#{Post.sequence_name}', #{@last_post_id})")
    end
    if @last_post_action_id > 0
      @raw_connection.exec("SELECT setval('#{PostAction.sequence_name}', #{@last_post_action_id})")
    end
    if @last_user_custom_field_id && @last_user_custom_field_id > 0
      @raw_connection.exec(
        "SELECT setval('#{UserCustomField.sequence_name}', #{@last_user_custom_field_id})",
      )
    end
    if @last_post_custom_field_id && @last_post_custom_field_id > 0
      @raw_connection.exec(
        "SELECT setval('#{PostCustomField.sequence_name}', #{@last_post_custom_field_id})",
      )
    end
    if @last_topic_custom_field_id && @last_topic_custom_field_id > 0
      @raw_connection.exec(
        "SELECT setval('#{TopicCustomField.sequence_name}', #{@last_topic_custom_field_id})",
      )
    end
    if @last_muted_user_id > 0
      @raw_connection.exec("SELECT setval('#{MutedUser.sequence_name}', #{@last_muted_user_id})")
    end
    if @last_user_history_id > 0
      @raw_connection.exec(
        "SELECT setval('#{UserHistory.sequence_name}', #{@last_user_history_id})",
      )
    end
    if @last_user_avatar_id > 0
      @raw_connection.exec("SELECT setval('#{UserAvatar.sequence_name}', #{@last_user_avatar_id})")
    end
    if @last_upload_id > 0
      @raw_connection.exec("SELECT setval('#{Upload.sequence_name}', #{@last_upload_id})")
    end
  end

  def group_id_from_imported_id(id)
    @groups[id.to_i]
  end

  def user_id_from_imported_id(id)
    @users[id.to_i]
  end

  def category_id_from_imported_id(id)
    @categories[id.to_i]
  end

  def topic_id_from_imported_id(id)
    @topics[id.to_i]
  end

  def post_id_from_imported_id(id)
    @posts[id.to_i]
  end

  def upload_id_from_original_id(id)
    @uploads_mapping[id.to_s]&.to_i
  end

  def upload_id_from_sha1(sha1)
    @uploads_by_sha1[sha1]
  end

  def post_number_from_imported_id(id)
    post_id = post_id_from_imported_id(id)
    post_id && @post_number_by_post_id[post_id]
  end

  def topic_id_from_imported_post_id(id)
    post_id = post_id_from_imported_id(id)
    post_id && @topic_id_by_post_id[post_id]
  end

  GROUP_COLUMNS ||= %i[
    id
    name
    full_name
    title
    bio_raw
    bio_cooked
    visibility_level
    members_visibility_level
    mentionable_level
    messageable_level
    created_at
    updated_at
  ]

  USER_COLUMNS ||= %i[
    id
    username
    username_lower
    name
    active
    trust_level
    admin
    moderator
    date_of_birth
    ip_address
    registration_ip_address
    primary_group_id
    suspended_at
    suspended_till
    last_seen_at
    last_emailed_at
    created_at
    updated_at
  ]

  USER_EMAIL_COLUMNS ||= %i[id user_id email primary created_at updated_at]

  USER_STAT_COLUMNS ||= %i[
    user_id
    topics_entered
    time_read
    days_visited
    posts_read_count
    likes_given
    likes_received
    new_since
    read_faq
    first_post_created_at
    post_count
    topic_count
    bounce_score
    reset_bounce_score_after
    digest_attempted_at
  ]

  USER_HISTORY_COLUMNS ||= %i[id action acting_user_id target_user_id details created_at updated_at]

  USER_AVATAR_COLUMNS ||= %i[id user_id custom_upload_id created_at updated_at]

  USER_PROFILE_COLUMNS ||= %i[user_id location website bio_raw bio_cooked views]

  USER_SSO_RECORD_COLUMNS ||= %i[
    id
    user_id
    external_id
    last_payload
    created_at
    updated_at
    external_username
    external_email
    external_name
    external_avatar_url
    external_profile_background_url
    external_card_background_url
  ]

  USER_OPTION_COLUMNS ||= %i[
    user_id
    mailing_list_mode
    mailing_list_mode_frequency
    email_level
    email_messages_level
    email_previous_replies
    email_in_reply_to
    email_digests
    digest_after_minutes
    include_tl0_in_digests
    automatically_unpin_topics
    enable_quoting
    external_links_in_new_tab
    dynamic_favicon
    new_topic_duration_minutes
    auto_track_topics_after_msecs
    notification_level_when_replying
    like_notification_frequency
    skip_new_user_tips
    hide_profile_and_presence
    sidebar_link_to_filtered_list
    sidebar_show_count_of_new_items
    timezone
  ]

  GROUP_USER_COLUMNS ||= %i[group_id user_id created_at updated_at]

  USER_CUSTOM_FIELD_COLUMNS ||= %i[id user_id name value created_at updated_at]

  POST_CUSTOM_FIELD_COLUMNS ||= %i[id post_id name value created_at updated_at]

  TOPIC_CUSTOM_FIELD_COLUMNS ||= %i[id topic_id name value created_at updated_at]

  USER_ACTION_COLUMNS ||= %i[
    action_type
    user_id
    target_topic_id
    target_post_id
    target_user_id
    acting_user_id
    created_at
    updated_at
  ]

  MUTED_USER_COLUMNS ||= %i[id user_id muted_user_id created_at updated_at]

  CATEGORY_COLUMNS ||= %i[
    id
    name
    name_lower
    slug
    user_id
    description
    position
    parent_category_id
    read_restricted
    uploaded_logo_id
    created_at
    updated_at
  ]

  CATEGORY_GROUP_COLUMNS ||= %i[id category_id group_id permission_type created_at updated_at]

  TOPIC_COLUMNS ||= %i[
    id
    archetype
    title
    fancy_title
    slug
    user_id
    last_post_user_id
    category_id
    visible
    closed
    pinned_at
    views
    subtype
    created_at
    bumped_at
    updated_at
  ]

  POST_COLUMNS ||= %i[
    id
    user_id
    last_editor_id
    topic_id
    post_number
    sort_order
    reply_to_post_number
    like_count
    raw
    cooked
    hidden
    word_count
    created_at
    last_version_at
    updated_at
  ]

  POST_ACTION_COLUMNS ||= %i[
    id
    post_id
    user_id
    post_action_type_id
    deleted_at
    created_at
    updated_at
    deleted_by_id
    related_post_id
    staff_took_action
    deferred_by_id
    targets_topic
    agreed_at
    agreed_by_id
    deferred_at
    disagreed_at
    disagreed_by_id
  ]

  TOPIC_ALLOWED_USER_COLUMNS ||= %i[topic_id user_id created_at updated_at]

  TOPIC_TAG_COLUMNS ||= %i[topic_id tag_id created_at updated_at]

  UPLOAD_COLUMNS ||= %i[
    id
    user_id
    original_filename
    filesize
    width
    height
    url
    created_at
    updated_at
    sha1
    origin
    retain_hours
    extension
    thumbnail_width
    thumbnail_height
    etag
    secure
    access_control_post_id
    original_sha1
    animated
    verification_status
    security_last_changed_at
    security_last_changed_reason
    dominant_color
  ]

  UPLOAD_REFERENCE_COLUMNS ||= %i[upload_id target_type target_id created_at updated_at]

  QUESTION_ANSWER_VOTE_COLUMNS ||= %i[user_id votable_type votable_id direction created_at]

  def create_groups(rows, &block)
    create_records(rows, "group", GROUP_COLUMNS, &block)
  end

  def create_users(rows, &block)
    @imported_usernames = {}

    create_records(rows, "user", USER_COLUMNS, &block)

    create_custom_fields("user", "username", @imported_usernames.keys) do |username|
      { record_id: @imported_usernames[username], value: username }
    end
  end

  def create_user_emails(rows, &block)
    create_records(rows, "user_email", USER_EMAIL_COLUMNS, &block)
  end

  def create_user_stats(rows, &block)
    create_records(rows, "user_stat", USER_STAT_COLUMNS, &block)
  end

  def create_user_histories(rows, &block)
    create_records(rows, "user_history", USER_HISTORY_COLUMNS, &block)
  end

  def create_user_avatars(rows, &block)
    create_records(rows, "user_avatar", USER_AVATAR_COLUMNS, &block)
  end

  def create_user_profiles(rows, &block)
    create_records(rows, "user_profile", USER_PROFILE_COLUMNS, &block)
  end

  def create_user_options(rows, &block)
    create_records(rows, "user_option", USER_OPTION_COLUMNS, &block)
  end

  def create_single_sign_on_records(rows, &block)
    create_records(rows, "single_sign_on_record", USER_SSO_RECORD_COLUMNS, &block)
  end

  def create_user_custom_fields(rows, &block)
    @last_user_custom_field_id = last_id(UserCustomField)
    create_records(rows, "user_custom_field", USER_CUSTOM_FIELD_COLUMNS, &block)
  end

  def create_muted_users(rows, &block)
    create_records(rows, "muted_user", MUTED_USER_COLUMNS, &block)
  end

  def create_group_users(rows, &block)
    create_records(rows, "group_user", GROUP_USER_COLUMNS, &block)
  end

  def create_categories(rows, &block)
    create_records(rows, "category", CATEGORY_COLUMNS, &block)
  end

  def create_category_groups(rows, &block)
    create_records(rows, "category_group", CATEGORY_GROUP_COLUMNS, &block)
  end

  def create_topics(rows, &block)
    create_records(rows, "topic", TOPIC_COLUMNS, &block)
  end

  def create_posts(rows, &block)
    create_records(rows, "post", POST_COLUMNS, &block)
  end

  def create_post_actions(rows, &block)
    create_records(rows, "post_action", POST_ACTION_COLUMNS, &block)
  end

  def create_topic_allowed_users(rows, &block)
    create_records(rows, "topic_allowed_user", TOPIC_ALLOWED_USER_COLUMNS, &block)
  end

  def create_topic_tags(rows, &block)
    create_records(rows, "topic_tag", TOPIC_TAG_COLUMNS, &block)
  end

  def create_uploads(rows, &block)
    @imported_uploads = {}
    create_records(rows, "upload", UPLOAD_COLUMNS, &block)
    store_mappings(MAPPING_TYPES[:upload], @imported_uploads)
  end

  def create_upload_references(rows, &block)
    create_records(rows, "upload_reference", UPLOAD_REFERENCE_COLUMNS, &block)
  end

  def create_question_answer_votes(rows, &block)
    create_records(rows, "question_answer_vote", QUESTION_ANSWER_VOTE_COLUMNS, &block)
  end

  def create_post_custom_fields(rows, &block)
    @last_post_custom_field_id = last_id(PostCustomField)
    create_records(rows, "post_custom_field", POST_CUSTOM_FIELD_COLUMNS, &block)
  end

  def create_topic_custom_fields(rows, &block)
    @last_topic_custom_field_id = last_id(TopicCustomField)
    create_records(rows, "topic_custom_field", TOPIC_CUSTOM_FIELD_COLUMNS, &block)
  end

  def create_user_actions(rows, &block)
    create_records(rows, "user_action", USER_ACTION_COLUMNS, &block)
  end

  def process_group(group)
    @groups[group[:imported_id].to_i] = group[:id] = @last_group_id += 1

    group[:name] = fix_name(group[:name])

    unless @usernames_and_groupnames_lower.add?(group[:name].downcase)
      group_name = group[:name] + "_1"
      group_name.next! until @usernames_and_groupnames_lower.add?(group_name.downcase)
      group[:name] = group_name
    end

    group[:title] = group[:title].scrub.strip.presence if group[:title].present?
    group[:bio_raw] = group[:bio_raw].scrub.strip.presence if group[:bio_raw].present?
    group[:bio_cooked] = pre_cook(group[:bio_raw]) if group[:bio_raw].present?

    group[:visibility_level] ||= Group.visibility_levels[:public]
    group[:members_visibility_level] ||= Group.visibility_levels[:public]
    group[:mentionable_level] ||= Group::ALIAS_LEVELS[:nobody]
    group[:messageable_level] ||= Group::ALIAS_LEVELS[:nobody]

    group[:created_at] ||= NOW
    group[:updated_at] ||= group[:created_at]
    group
  end

  def process_user(user)
    if user[:email].present?
      user[:email].downcase!

      if (existing_user_id = @emails[user[:email]])
        @users[user[:imported_id].to_i] = existing_user_id
        user[:skip] = true
        return user
      end
    end

    if user[:external_id].present?
      if (existing_user_id = @external_ids[user[:external_id]])
        @users[user[:imported_id].to_i] = existing_user_id
        user[:skip] = true
        return user
      end
    end

    @users[user[:imported_id].to_i] = user[:id] = @last_user_id += 1

    imported_username = user[:original_username].presence || user[:username].dup

    user[:username] = fix_name(user[:username]).presence || random_username

    if user[:username] != imported_username
      @imported_usernames[imported_username] = user[:id]
      @mapped_usernames[imported_username] = user[:username]
    end

    # unique username_lower
    unless @usernames_and_groupnames_lower.add?(user[:username].downcase)
      username = user[:username] + "_1"
      username.next! until @usernames_and_groupnames_lower.add?(username.downcase)
      user[:username] = username
    end

    user[:username_lower] = user[:username].downcase
    user[:trust_level] ||= TrustLevel[1]
    user[:active] = true unless user.has_key?(:active)
    user[:admin] ||= false
    user[:moderator] ||= false
    user[:last_emailed_at] ||= NOW
    user[:created_at] ||= NOW
    user[:updated_at] ||= user[:created_at]
    user[:suspended_at] ||= user[:suspended_at]
    user[:suspended_till] ||= user[:suspended_till] ||
      (200.years.from_now if user[:suspended_at].present?)

    if (date_of_birth = user[:date_of_birth]).is_a?(Date) && date_of_birth.year != 1904
      user[:date_of_birth] = Date.new(1904, date_of_birth.month, date_of_birth.day)
    end

    user
  end

  def process_user_email(user_email)
    user_email[:id] = @last_user_email_id += 1
    user_email[:primary] = true
    user_email[:created_at] ||= NOW
    user_email[:updated_at] ||= user_email[:created_at]

    user_email[:email] = user_email[:email]&.downcase || random_email
    # unique email
    user_email[:email] = random_email until EmailAddressValidator.valid_value?(
      user_email[:email],
    ) && !@emails.has_key?(user_email[:email])

    user_email
  end

  def process_user_stat(user_stat)
    user_stat[:user_id] = user_id_from_imported_id(user_email[:imported_user_id])
    user_stat[:topics_entered] ||= 0
    user_stat[:time_read] ||= 0
    user_stat[:days_visited] ||= 0
    user_stat[:posts_read_count] ||= 0
    user_stat[:likes_given] ||= 0
    user_stat[:likes_received] ||= 0
    user_stat[:new_since] ||= NOW
    user_stat[:post_count] ||= 0
    user_stat[:topic_count] ||= 0
    user_stat[:bounce_score] ||= 0
    user_stat[:digest_attempted_at] ||= NOW
    user_stat
  end

  def process_user_history(history)
    history[:id] = @last_user_history_id += 1
    history[:created_at] ||= NOW
    history[:updated_at] ||= NOW
    history
  end

  def process_muted_user(muted_user)
    muted_user[:id] = @last_muted_user_id += 1
    muted_user[:created_at] ||= NOW
    muted_user[:updated_at] ||= NOW
    muted_user
  end

  def process_user_profile(user_profile)
    user_profile[:bio_raw] = (user_profile[:bio_raw].presence || "").scrub.strip.presence
    user_profile[:bio_cooked] = pre_cook(user_profile[:bio_raw]) if user_profile[:bio_raw].present?
    user_profile[:views] ||= 0
    user_profile
  end

  USER_OPTION_DEFAULTS = {
    mailing_list_mode: SiteSetting.default_email_mailing_list_mode,
    mailing_list_mode_frequency: SiteSetting.default_email_mailing_list_mode_frequency,
    email_level: SiteSetting.default_email_level,
    email_messages_level: SiteSetting.default_email_messages_level,
    email_previous_replies: SiteSetting.default_email_previous_replies,
    email_in_reply_to: SiteSetting.default_email_in_reply_to,
    email_digests: SiteSetting.default_email_digest_frequency.to_i > 0,
    digest_after_minutes: SiteSetting.default_email_digest_frequency,
    include_tl0_in_digests: SiteSetting.default_include_tl0_in_digests,
    automatically_unpin_topics: SiteSetting.default_topics_automatic_unpin,
    enable_quoting: SiteSetting.default_other_enable_quoting,
    external_links_in_new_tab: SiteSetting.default_other_external_links_in_new_tab,
    dynamic_favicon: SiteSetting.default_other_dynamic_favicon,
    new_topic_duration_minutes: SiteSetting.default_other_new_topic_duration_minutes,
    auto_track_topics_after_msecs: SiteSetting.default_other_auto_track_topics_after_msecs,
    notification_level_when_replying: SiteSetting.default_other_notification_level_when_replying,
    like_notification_frequency: SiteSetting.default_other_like_notification_frequency,
    skip_new_user_tips: SiteSetting.default_other_skip_new_user_tips,
    hide_profile_and_presence: SiteSetting.default_hide_profile_and_presence,
    sidebar_link_to_filtered_list: SiteSetting.default_sidebar_link_to_filtered_list,
    sidebar_show_count_of_new_items: SiteSetting.default_sidebar_show_count_of_new_items,
  }

  def process_user_option(user_option)
    USER_OPTION_DEFAULTS.each { |key, value| user_option[key] = value if user_option[key].nil? }
    user_option
  end

  def process_single_sign_on_record(sso_record)
    sso_record[:id] = @last_sso_record_id += 1
    sso_record[:last_payload] ||= ""
    sso_record[:created_at] = NOW
    sso_record[:updated_at] = NOW
    sso_record
  end

  def process_group_user(group_user)
    group_user[:created_at] = NOW
    group_user[:updated_at] = NOW
    group_user
  end

  def process_category(category)
    if category[:existing_id].present?
      @categories[category[:imported_id].to_i] = category[:existing_id]
      category[:skip] = true
      return category
    end

    category[:id] ||= @last_category_id += 1
    @categories[category[:imported_id].to_i] ||= category[:id]

    next_number = 1
    original_name = name = category[:name][0...50].scrub.strip

    while @category_names.include?("#{category[:parent_category_id]}-#{name.downcase}")
      name = "#{original_name[0...50 - next_number.to_s.length]}#{next_number}"
      next_number += 1
    end

    @category_names << "#{category[:parent_category_id]}-#{name.downcase}"
    name_lower = name.downcase

    category[:name] = name
    category[:name_lower] = name_lower
    category[:slug] ||= Slug.ascii_generator(name_lower)
    category[:description] = (category[:description] || "").scrub.strip.presence
    category[:user_id] ||= Discourse::SYSTEM_USER_ID
    category[:read_restricted] = false if category[:read_restricted].nil?
    category[:created_at] ||= NOW
    category[:updated_at] ||= category[:created_at]

    if category[:position]
      @highest_category_position = category[:position] if category[:position] >
        @highest_category_position
    else
      category[:position] = @highest_category_position += 1
    end

    category
  end

  def process_category_group(category_group)
    category_group[:id] = @last_category_group_id += 1
    category_group[:created_at] = NOW
    category_group[:updated_at] = NOW
    category_group
  end

  def process_topic(topic)
    @topics[topic[:imported_id].to_i] = topic[:id] = @last_topic_id += 1
    topic[:archetype] ||= Archetype.default
    topic[:title] = topic[:title][0...255].scrub.strip
    topic[:fancy_title] ||= pre_fancy(topic[:title])
    topic[:slug] ||= Slug.ascii_generator(topic[:title])
    topic[:user_id] ||= Discourse::SYSTEM_USER_ID
    topic[:last_post_user_id] ||= topic[:user_id]
    topic[:category_id] ||= -1 if topic[:archetype] != Archetype.private_message
    topic[:visible] = true unless topic.has_key?(:visible)
    topic[:closed] ||= false
    topic[:views] ||= 0
    topic[:created_at] ||= NOW
    topic[:bumped_at] ||= topic[:created_at]
    topic[:updated_at] ||= topic[:created_at]
    topic
  end

  def process_post(post)
    @posts[post[:imported_id].to_i] = post[:id] = @last_post_id += 1
    post[:user_id] ||= Discourse::SYSTEM_USER_ID
    post[:last_editor_id] = post[:user_id]
    @highest_post_number_by_topic_id[post[:topic_id]] ||= 0
    post[:post_number] = @highest_post_number_by_topic_id[post[:topic_id]] += 1
    post[:sort_order] = post[:post_number]
    @post_number_by_post_id[post[:id]] = post[:post_number]
    @topic_id_by_post_id[post[:id]] = post[:topic_id]
    post[:raw] = (post[:raw] || "").scrub.strip.presence || "<Empty imported post>"
    post[:raw] = process_raw post[:raw]
    if @bbcode_to_md
      post[:raw] = begin
        post[:raw].bbcode_to_md(false, {}, :disable, :quote)
      rescue StandardError
        post[:raw]
      end
    end
    post[:raw] = normalize_text(post[:raw])
    post[:like_count] ||= 0
    post[:cooked] = pre_cook post[:raw]
    post[:hidden] ||= false
    post[:word_count] = post[:raw].scan(/[[:word:]]+/).size
    post[:created_at] ||= NOW
    post[:last_version_at] = post[:created_at]
    post[:updated_at] ||= post[:created_at]

    if post[:raw].bytes.include?(0)
      STDERR.puts "Skipping post with original ID #{post[:imported_id]} because `raw` contains null bytes"
      post[:skip] = true
    end

    post[:reply_to_post_number] = nil if post[:reply_to_post_number] == 1

    if post[:cooked].bytes.include?(0)
      STDERR.puts "Skipping post with original ID #{post[:imported_id]} because `cooked` contains null bytes"
      post[:skip] = true
    end

    post
  end

  def process_post_action(post_action)
    post_action[:id] ||= @last_post_action_id += 1
    post_action[:staff_took_action] ||= false
    post_action[:targets_topic] ||= false
    post_action[:created_at] ||= NOW
    post_action[:updated_at] ||= post_action[:created_at]
    post_action
  end

  def process_topic_allowed_user(topic_allowed_user)
    topic_allowed_user[:created_at] = NOW
    topic_allowed_user[:updated_at] = NOW
    topic_allowed_user
  end

  def process_topic_tag(topic_tag)
    topic_tag[:created_at] = NOW
    topic_tag[:updated_at] = NOW
    topic_tag
  end

  def process_upload(upload)
    if (existing_upload_id = upload_id_from_sha1(upload[:sha1]))
      @imported_uploads[upload[:original_id]] = existing_upload_id
      @uploads_mapping[upload[:original_id]] = existing_upload_id
      return { skip: true }
    end

    upload[:id] = @last_upload_id += 1
    upload[:user_id] ||= Discourse::SYSTEM_USER_ID
    upload[:created_at] ||= NOW
    upload[:updated_at] ||= NOW

    @imported_uploads[upload[:original_id]] = upload[:id]
    @uploads_mapping[upload[:original_id]] = upload[:id]
    @uploads_by_sha1[upload[:sha1]] = upload[:id]

    upload
  end

  def process_upload_reference(upload_reference)
    upload_reference[:created_at] ||= NOW
    upload_reference[:updated_at] ||= NOW
    upload_reference
  end

  def process_question_answer_vote(question_answer_vote)
    question_answer_vote[:created_at] ||= NOW
    question_answer_vote
  end

  def process_user_avatar(avatar)
    avatar[:id] = @last_user_avatar_id += 1
    avatar[:created_at] ||= NOW
    avatar[:updated_at] ||= NOW
    avatar
  end

  def process_raw(original_raw)
    raw = original_raw.dup
    # fix whitespaces
    raw.gsub!(/(\\r)?\\n/, "\n")
    raw.gsub!("\\t", "\t")

    # [HTML]...[/HTML]
    raw.gsub!(/\[HTML\]/i, "\n\n```html\n")
    raw.gsub!(%r{\[/HTML\]}i, "\n```\n\n")

    # [PHP]...[/PHP]
    raw.gsub!(/\[PHP\]/i, "\n\n```php\n")
    raw.gsub!(%r{\[/PHP\]}i, "\n```\n\n")

    # [HIGHLIGHT="..."]
    raw.gsub!(/\[HIGHLIGHT="?(\w+)"?\]/i) { "\n\n```#{$1.downcase}\n" }

    # [CODE]...[/CODE]
    # [HIGHLIGHT]...[/HIGHLIGHT]
    raw.gsub!(%r{\[/?CODE\]}i, "\n\n```\n\n")
    raw.gsub!(%r{\[/?HIGHLIGHT\]}i, "\n\n```\n\n")

    # [SAMP]...[/SAMP]
    raw.gsub!(%r{\[/?SAMP\]}i, "`")

    # replace all chevrons with HTML entities
    # /!\ must be done /!\
    #  - AFTER the "code" processing
    #  - BEFORE the "quote" processing
    raw.gsub!(/`([^`]+?)`/im) { "`" + $1.gsub("<", "\u2603") + "`" }
    raw.gsub!("<", "&lt;")
    raw.gsub!("\u2603", "<")

    raw.gsub!(/`([^`]+?)`/im) { "`" + $1.gsub(">", "\u2603") + "`" }
    raw.gsub!(">", "&gt;")
    raw.gsub!("\u2603", ">")

    raw.gsub!(%r{\[/?I\]}i, "*")
    raw.gsub!(%r{\[/?B\]}i, "**")
    raw.gsub!(%r{\[/?U\]}i, "")

    raw.gsub!(%r{\[/?RED\]}i, "")
    raw.gsub!(%r{\[/?BLUE\]}i, "")

    raw.gsub!(%r{\[AUTEUR\].+?\[/AUTEUR\]}im, "")
    raw.gsub!(%r{\[VOIRMSG\].+?\[/VOIRMSG\]}im, "")
    raw.gsub!(%r{\[PSEUDOID\].+?\[/PSEUDOID\]}im, "")

    # [IMG]...[/IMG]
    raw.gsub!(%r{(?:\s*\[IMG\]\s*)+(.+?)(?:\s*\[/IMG\]\s*)+}im) { "\n\n#{$1}\n\n" }

    # [IMG=url]
    raw.gsub!(/\[IMG=([^\]]*)\]/im) { "\n\n#{$1}\n\n" }

    # [URL=...]...[/URL]
    raw.gsub!(%r{\[URL="?(.+?)"?\](.+?)\[/URL\]}im) { "[#{$2.strip}](#{$1})" }

    # [URL]...[/URL]
    # [MP3]...[/MP3]
    # [EMAIL]...[/EMAIL]
    # [LEFT]...[/LEFT]
    raw.gsub!(%r{\[/?URL\]}i, "")
    raw.gsub!(%r{\[/?MP3\]}i, "")
    raw.gsub!(%r{\[/?EMAIL\]}i, "")
    raw.gsub!(%r{\[/?LEFT\]}i, "")

    # [FONT=blah] and [COLOR=blah]
    raw.gsub!(%r{\[FONT=.*?\](.*?)\[/FONT\]}im, "\\1")
    raw.gsub!(%r{\[COLOR=.*?\](.*?)\[/COLOR\]}im, "\\1")

    raw.gsub!(%r{\[SIZE=.*?\](.*?)\[/SIZE\]}im, "\\1")
    raw.gsub!(%r{\[H=.*?\](.*?)\[/H\]}im, "\\1")

    # [CENTER]...[/CENTER]
    raw.gsub!(%r{\[CENTER\](.*?)\[/CENTER\]}im, "\\1")

    # [INDENT]...[/INDENT]
    raw.gsub!(%r{\[INDENT\](.*?)\[/INDENT\]}im, "\\1")
    raw.gsub!(%r{\[TABLE\](.*?)\[/TABLE\]}im, "\\1")
    raw.gsub!(%r{\[TR\](.*?)\[/TR\]}im, "\\1")
    raw.gsub!(%r{\[TD\](.*?)\[/TD\]}im, "\\1")
    raw.gsub!(%r{\[TD="?.*?"?\](.*?)\[/TD\]}im, "\\1")

    # [STRIKE]
    raw.gsub!(/\[STRIKE\]/i, "<s>")
    raw.gsub!(%r{\[/STRIKE\]}i, "</s>")

    # [QUOTE]...[/QUOTE]
    raw.gsub!(/\[QUOTE="([^\]]+)"\]/i) { "[QUOTE=#{$1}]" }

    # Nested Quotes
    raw.gsub!(%r{(\[/?QUOTE.*?\])}mi) { |q| "\n#{q}\n" }

    # raw.gsub!(/\[QUOTE\](.+?)\[\/QUOTE\]/im) { |quote|
    #   quote.gsub!(/\[QUOTE\](.+?)\[\/QUOTE\]/im) { "\n#{$1}\n" }
    #   quote.gsub!(/\n(.+?)/) { "\n> #{$1}" }
    # }

    # [QUOTE=<username>;<postid>]
    raw.gsub!(/\[QUOTE=([^;\]]+);(\d+)\]/i) do
      imported_username, imported_postid = $1, $2

      username = @mapped_usernames[imported_username] || imported_username
      post_number = post_number_from_imported_id(imported_postid)
      topic_id = topic_id_from_imported_post_id(imported_postid)

      if post_number && topic_id
        "\n[quote=\"#{username}, post:#{post_number}, topic:#{topic_id}\"]\n"
      else
        "\n[quote=\"#{username}\"]\n"
      end
    end

    # [YOUTUBE]<id>[/YOUTUBE]
    raw.gsub!(%r{\[YOUTUBE\](.+?)\[/YOUTUBE\]}i) { "\nhttps://www.youtube.com/watch?v=#{$1}\n" }
    raw.gsub!(%r{\[DAILYMOTION\](.+?)\[/DAILYMOTION\]}i) do
      "\nhttps://www.dailymotion.com/video/#{$1}\n"
    end

    # [VIDEO=youtube;<id>]...[/VIDEO]
    raw.gsub!(%r{\[VIDEO=YOUTUBE;([^\]]+)\].*?\[/VIDEO\]}i) do
      "\nhttps://www.youtube.com/watch?v=#{$1}\n"
    end
    raw.gsub!(%r{\[VIDEO=DAILYMOTION;([^\]]+)\].*?\[/VIDEO\]}i) do
      "\nhttps://www.dailymotion.com/video/#{$1}\n"
    end

    # [SPOILER=Some hidden stuff]SPOILER HERE!![/SPOILER]
    raw.gsub!(%r{\[SPOILER="?(.+?)"?\](.+?)\[/SPOILER\]}im) do
      "\n#{$1}\n[spoiler]#{$2}[/spoiler]\n"
    end

    # convert list tags to ul and list=1 tags to ol
    # (basically, we're only missing list=a here...)
    # (https://meta.discourse.org/t/phpbb-3-importer-old/17397)
    raw.gsub!(%r{\[list\](.*?)\[/list\]}im, '[ul]\1[/ul]')
    raw.gsub!(%r{\[list=1\|?[^\]]*\](.*?)\[/list\]}im, '[ol]\1[/ol]')
    raw.gsub!(%r{\[list\](.*?)\[/list:u\]}im, '[ul]\1[/ul]')
    raw.gsub!(%r{\[list=1\|?[^\]]*\](.*?)\[/list:o\]}im, '[ol]\1[/ol]')
    # convert *-tags to li-tags so bbcode-to-md can do its magic on phpBB's lists:
    raw.gsub!(/\[\*\]\n/, "")
    raw.gsub!(%r{\[\*\](.*?)\[/\*:m\]}, '[li]\1[/li]')
    raw.gsub!(/\[\*\](.*?)\n/, '[li]\1[/li]')
    raw.gsub!(/\[\*=1\]/, "")

    raw
  end

  def process_user_custom_field(field)
    field[:id] ||= @last_user_custom_field_id += 1
    field[:created_at] ||= NOW
    field[:updated_at] ||= NOW
    field
  end

  def process_post_custom_field(field)
    field[:id] ||= @last_post_custom_field_id += 1
    field[:created_at] ||= NOW
    field[:updated_at] ||= NOW
    field
  end

  def process_topic_custom_field(field)
    field[:id] ||= @last_topic_custom_field_id += 1
    field[:created_at] ||= NOW
    field[:updated_at] ||= NOW
    field
  end

  def process_user_action(user_action)
    user_action[:created_at] ||= NOW
    user_action[:updated_at] ||= NOW
    user_action
  end

  def create_records(all_rows, name, columns)
    start = Time.now
    imported_ids = []
    process_method_name = "process_#{name}"

    rows_created = 0

    all_rows.each_slice(1_000) do |rows|
      sql = "COPY #{name.pluralize} (#{columns.map { |c| "\"#{c}\"" }.join(",")}) FROM STDIN"

      begin
        @raw_connection.copy_data(sql, @encoder) do
          rows.each do |row|
            begin
              if (mapped = yield(row))
                processed = send(process_method_name, mapped)
                imported_ids << mapped[:imported_id] unless mapped[:imported_id].nil?
                imported_ids |= mapped[:imported_ids] unless mapped[:imported_ids].nil?
                unless processed[:skip]
                  @raw_connection.put_copy_data columns.map { |c| processed[c] }
                end
              end
              rows_created += 1
              if rows_created % 100 == 0
                print "\r%7d - %6d/sec" % [rows_created, rows_created.to_f / (Time.now - start)]
              end
            rescue => e
              puts "\n"
              puts "ERROR: #{e.message}"
              puts e.backtrace.join("\n")
            end
          end
        end
      rescue => e
        puts "First Row: #{rows.first.inspect}"
        raise e
      end
    end

    if rows_created > 0
      print "\r%7d - %6d/sec\n" % [rows_created, rows_created.to_f / (Time.now - start)]
    end

    id_mapping_method_name = "#{name}_id_from_imported_id".freeze
    return unless respond_to?(id_mapping_method_name)
    create_custom_fields(name, "id", imported_ids) do |imported_id|
      { record_id: send(id_mapping_method_name, imported_id), value: imported_id }
    end
  rescue => e
    # FIXME: errors catched here stop the rest of the COPY
    puts e.message
    puts e.backtrace.join("\n")
  end

  def create_custom_fields(table, name, rows)
    name = "import_#{name}"
    sql =
      "COPY #{table}_custom_fields (#{table}_id, name, value, created_at, updated_at) FROM STDIN"
    @raw_connection.copy_data(sql, @encoder) do
      rows.each do |row|
        next unless cf = yield(row)
        @raw_connection.put_copy_data [cf[:record_id], name, cf[:value], NOW, NOW]
      end
    end
  end

  def store_mappings(type, rows)
    return if rows.empty?

    sql = "COPY migration_mappings (original_id, type, discourse_id) FROM STDIN"
    @raw_connection.copy_data(sql, @encoder) do
      rows.each do |original_id, discourse_id|
        @raw_connection.put_copy_data [original_id, type, discourse_id]
      end
    end
  end

  def create_upload(user_id, path, source_filename)
    @uploader.create_upload(user_id, path, source_filename)
  end

  def html_for_upload(upload, display_filename)
    @uploader.html_for_upload(upload, display_filename)
  end

  def fix_name(name)
    name.scrub! if name && !name.valid_encoding?
    return if name.blank?
    # TODO Support Unicode if allowed in site settings and try to reuse logic from UserNameSuggester if possible
    name = ActiveSupport::Inflector.transliterate(name)
    name.gsub!(/[^\w.-]+/, "_")
    name.gsub!(/^\W+/, "")
    name.gsub!(/[^A-Za-z0-9]+$/, "")
    name.gsub!(/([-_.]{2,})/) { $1.first }
    name.strip!
    name.truncate(60)
    name
  end

  def random_username
    "Anonymous_#{SecureRandom.hex}"
  end

  def random_email
    "#{SecureRandom.hex}@email.invalid"
  end

  def pre_cook(raw)
    # TODO Check if this is still up-to-date
    # Convert YouTube URLs to lazyYT DOMs before being transformed into links
    cooked =
      raw.gsub(%r{\nhttps\://www.youtube.com/watch\?v=(\w+)\n}) do
        video_id = $1
        result = <<-HTML
        <div class="lazyYT" data-youtube-id="#{video_id}" data-width="480" data-height="270" data-parameters="feature=oembed&amp;wmode=opaque"></div>
        HTML
        result.strip
      end

    cooked = @markdown.render(cooked).scrub.strip

    cooked.gsub!(%r{\[QUOTE="?([^,"]+)(?:, post:(\d+), topic:(\d+))?"?\](.+?)\[/QUOTE\]}im) do
      username, post_id, topic_id, quote = $1, $2, $3, $4

      quote = quote.scrub.strip
      quote.gsub!(/^(<br>\n?)+/, "")
      quote.gsub!(/(<br>\n?)+$/, "")

      user = User.find_by(username: username)

      if post_id.present? && topic_id.present?
        <<-HTML
          <aside class="quote" data-post="#{post_id}" data-topic="#{topic_id}">
            <div class="title">
              <div class="quote-controls"></div>
              #{user ? user_avatar(user) : username}:
            </div>
            <blockquote>#{quote}</blockquote>
          </aside>
        HTML
      else
        <<-HTML
          <aside class="quote no-group" data-username="#{username}">
            <div class="title">
              <div class="quote-controls"></div>
              #{user ? user_avatar(user) : username}:
            </div>
            <blockquote>#{quote}</blockquote>
          </aside>
        HTML
      end
    end

    # TODO Check if scrub or strip is inserting \x00 which is causing Postgres COPY to fail
    cooked.scrub.strip
    cooked.gsub!(/\x00/, "")
    cooked
  end

  def user_avatar(user)
    url = user.avatar_template.gsub("{size}", "45")
    "<img alt=\"\" width=\"20\" height=\"20\" src=\"#{url}\" class=\"avatar\"> #{user.username}"
  end

  def pre_fancy(title)
    Redcarpet::Render::SmartyPants.render(ERB::Util.html_escape(title)).scrub.strip
  end

  def normalize_text(text)
    return nil unless text.present?
    @html_entities.decode(normalize_charset(text.presence || "").scrub)
  end

  def normalize_charset(text)
    return text if @encoding == Encoding::UTF_8
    text && text.encode(@encoding).force_encoding(Encoding::UTF_8)
  end
end
