class Game < ActiveRecord::Base
  belongs_to :creator, :class_name => 'User', :foreign_key => 'creator_id'
  belongs_to :winner, :class_name => 'User', :foreign_key => 'winner_id'

  has_many :players, :inverse_of => :game, :autosave => true, :dependent => :destroy
  has_many :cards, :inverse_of => :game, :autosave => true, :dependent => :destroy
  has_many :nobles, :inverse_of => :game, :autosave => true, :dependent => :destroy

  private
  STATUS_WAITING_FOR_PLAYERS = 1
  STATUS_PLAYING = 2
  STATUS_LAST_TURN= 3
  STATUS_COMPLETED = 4

  public
  include ChipOwner

  validates_presence_of :creator

  validates :status, :presence => true, 
            :inclusion => { :in => [STATUS_WAITING_FOR_PLAYERS, 
             STATUS_PLAYING, STATUS_LAST_TURN, STATUS_COMPLETED] }

  validates :num_players, :presence => true, :inclusion => { :in => 2.upto(4), :message => " should be 2 3 or 4" }

  validates :turn_num, :presence => true, 
            :numericality => {:only_integer => true, :greater_than => 0}

  def waiting_for_players?
    status == STATUS_WAITING_FOR_PLAYERS
  end

  def playing?
    status == STATUS_PLAYING
  end

  def last_turn?
    status == STATUS_LAST_TURN
  end

  def completed?
    status == STATUS_COMPLETED
  end

  #returns the player for a corresponding user, or nil if they aren't playing
  #Since this works for anything with an id, and id's are not guaranteed to be unique 
  #across different types of items, would it make sense to use email address?
  def player(user)
    players.detect { |p| p.user_id == user.id } if user != nil
  end

  def player?(user)
    player(user) != nil
  end  

  #this allows us to roll back game creation if the player fails to be added for the
  #creator. this would be an unexpected error, but at least no one will ever be left
  #wondering why they're not in the game they just created when they normally are
  after_create :after_create_add_creators_player
  def after_create_add_creators_player
    raise ActiveRecord::Rollback unless add_user?(creator)
  end

  def add_user?(user)
    if user != nil && user.confirmed? && waiting_for_players? && !player?(user) 
      player = players.build
      player.user = user
      save
    end
  end

  def remove_player?(player)
    if waiting_for_players? && player != nil && players.find_by_id(player.id) != nil
      #the size check is a fallback if the creator somehow leaves 
      #without deleting the game. It's just to avoid old empty games
      if player.user == creator || players.size == 1
        destroy
      else
        player.destroy
      end
    end
  end

  #when saving a game, initialize it for play if it's full but status is still waiting
  after_save do
    if num_players == players.length && waiting_for_players?
      raise ActiveRecord::Rollback unless init_game?
    end
    true
  end

  def get_top_card_of_level(level)
    return cards.find{|card| card.level == level && card.position == 1}
  end

  def get_card_by_id(id)
    return cards.find{|card| card.id == id}
  end

  def get_noble_by_id(id)
    return nobles.find{|noble| noble.id == id}
  end

  def take_chips(player, taken, returned)
    if player.turn_status != TAKING_TURN
      raise "Not currently player's turn"
    end

    if taken.count > 3 || taken.count + player.chip_count - returned.count > 10
      raise "Took too many chips"
    end

    if taken.count + player.chip_count - returned.count < 10 && returned.count != 0
      raise "Returned too many chips"
    end

    if taken.gold != 0
      raise "Not allowed to take gold chips"
    end

    #validations will handle negative chip counts. see chip_owner

    [[taken.blue, blue_chips], [taken.red, red_chips], [taken.green, green_chips], 
    [taken.black, black_chips], [taken.white, white_chips]].each do |taken_color, game_color|
      if taken_color < 0 || taken_color > 2 || (taken_color == 2 && (game_color < 4 || taken.count != 2))
        raise "Invalid chips taken"
      end
    end

    #TODO: maybe add a check to see if they didn't take enough chips

    player.add_chips(taken)
    player.subtract_chips(returned)
    subtract_chips(taken)
    add_chips(returned)

    finish_turn(player)
    save!
  end

  def reserve_card(player, card, returned)
    if player.turn_status != TAKING_TURN
      raise "Not currently player's turn"
    end

    if returned.count > 1 || returned.count == 1 && (game.gold_chips == 0 || player.chip_count != 10)
      raise "Returned too many chips"
    end

    if player.chip_count == 10 && returned.count == 0 && gold_chips != 0
      raise "Need to return chips"
    end

    if card.position != 0 && card.position != 1
      raise "That card can't be reserved"
    end

    if player.reserved_cards.size == 3
      raise "Only 3 cards can be reserved at a time"
    end

    card.player = player
    card.position = -1
    card.is_reserved = true

    if gold_chips != 0
      self.gold_chips -=1
      player.gold_chips += 1
    end
    player.subtract_chips(returned)
    add_chips(returned)

    finish_turn(player)
    save!
  end

  def buy_card(player, card, spent)
    if player.turn_status != TAKING_TURN
      raise "Not currently player's turn"
    end

    if card.position != 0 && (card.player != player || !card.is_reserved)
      raise "That card can't be bought right now"
    end

    was_reserved = card.is_reserved
    raise "Can't buy card with those chips" unless player.can_buy_card?(card, spent)
    player.subtract_chips(spent)
    add_chips(spent)
    player.cards << card
    card.player = player
    card.is_reserved = false
    card.position = -1

    if !was_reserved
      cards.select {|deck_card| deck_card.level == card.level && deck_card.position > 0}.each do |deck_card|
        deck_card.position -= 1
      end
    end

    finish_turn(player)
    save!
  end

  def choose_noble(player, noble)
    if player.turn_status != CHOOSING_NOBLE
      raise "Can't choose a noble right now"
    end

    if noble.player != nil
      raise "That noble is already taken"
    end

    if !player.can_afford_noble?(noble)
      raise "Can't afford that noble"
    end

    player.nobles << noble
    noble.player = player
    advance_turns(player)
    save!
  end

  private
  def finish_turn(player)
    available_nobles = nobles.select{|noble| !noble.player && player.can_afford_noble?(noble) }

    if available_nobles.count > 1
      player.turn_status = CHOOSING_NOBLE
      return
    elsif available_nobles.count == 1
      player.nobles << available_nobles.first
      available_nobles.first.player = player
    end
    advance_turns(player)
  end

  def advance_turns(player)
    player.turn_status = WAITING_FOR_TURN
    if (player.victory_points >= 15 || last_turn?) && player.turn_num == num_players
      finish_game
      return
    elsif player.victory_points >= 15
      self.status = STATUS_LAST_TURN
    end

    players.find{|p| p.turn_num == (player.turn_num % num_players) + 1 }.turn_status = TAKING_TURN
    if player.turn_num == num_players
      self.turn_num += 1
    end
  end

  def finish_game
    self.status = STATUS_COMPLETED
    potential_winners = players.group_by {|p| p.victory_points}.max.last
    if potential_winners.count > 1
      potential_winners = potential_winners.group_by {|p| p.played_cards.count}.min.last

      if potential_winners.count > 1
        potential_winners = potential_winners.group_by {|p| p.chip_count}.max.last

        if potential_winners.count > 1
          potential_winners = [potential_winners.max_by {|p| p.turn_num}]
        end
      end
    end

    self.winner = potential_winners.first.user
  end

  def init_game?
    #give each player their own turn
    players.shuffle.each_with_index do |player, index|
      player.turn_num = index + 1
      player.turn_status = (index == 0 ? TAKING_TURN : WAITING_FOR_TURN)
      player.blue_chips = 0
      player.red_chips = 0
      player.green_chips = 0
      player.white_chips = 0
      player.black_chips = 0
      player.gold_chips = 0
    end

    default_chip_count = num_players == 4 ? 7 : (num_players == 3 ? 5 : 4)
    self.blue_chips = default_chip_count
    self.red_chips = default_chip_count
    self.green_chips = default_chip_count
    self.white_chips = default_chip_count
    self.black_chips = default_chip_count
    self.gold_chips = 5

    card_list = nil
    File.open(File.join(Rails.root, 'lib', 'assets', 'card_list.json')) do |f|
      card_list = JSON.load f
    end

    card_list.each do |card_data|
      cards.build card_data
    end

    #shuffle cards
    (1..3).each do |level|
      cur_cards = cards.select {|card| card.level == level}.shuffle
      cur_cards.last(cur_cards.length - 4).each_with_index { |card, index| card.position = index + 1 }
    end

    noble_list = nil
    File.open(File.join(Rails.root, 'lib', 'assets', 'noble_list.json')) do |f|
      noble_list = JSON.load f
    end

    noble_list.sample(num_players + 1).each do |noble_data|
      nobles.build noble_data
    end

    self.status = STATUS_PLAYING
    save
  end
end
