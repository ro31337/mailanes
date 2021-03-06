# frozen_string_literal: true

# Copyright (c) 2018 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'yaml'
require_relative 'pgsql'
require_relative 'lane'
require_relative 'list'
require_relative 'pipeline'

# Campaign.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018 Yegor Bugayenko
# License:: MIT
class Campaign
  attr_reader :id

  def initialize(id:, pgsql: Pgsql::TEST, hash: {})
    raise "Invalid ID: #{id} (#{id.class.name})" unless id.is_a?(Integer)
    @id = id
    @pgsql = pgsql
    @hash = hash
  end

  def add(list)
    @pgsql.exec(
      'INSERT INTO source (list, campaign) VALUES ($1, $2) RETURNING id',
      [list.id, @id]
    )[0]
  end

  def delete(list)
    @pgsql.exec(
      'DELETE FROM source WHERE list = $1 AND campaign = $2',
      [list.id, @id]
    )[0]
  end

  def lists
    q = 'SELECT list.* FROM list JOIN source ON source.list = list.id WHERE source.campaign = $1'
    @pgsql.exec(q, [@id]).map do |r|
      List.new(id: r['id'].to_i, pgsql: @pgsql, hash: r)
    end
  end

  def lane
    hash = @pgsql.exec(
      'SELECT lane.* FROM lane JOIN campaign ON campaign.lane=lane.id WHERE campaign.id=$1',
      [@id]
    )[0]
    Lane.new(
      id: hash['id'].to_i,
      pgsql: @pgsql,
      hash: hash
    )
  end

  def title
    yaml['title'] || 'unknown'
  end

  def yaml
    YAML.safe_load(
      @hash['yaml'] || @pgsql.exec('SELECT yaml FROM campaign WHERE id=$1', [@id])[0]['yaml']
    )
  end

  def save_yaml(yaml)
    yml = YAML.safe_load(yaml)
    @pgsql.exec('UPDATE campaign SET yaml=$1 WHERE id=$2', [yaml, @id])
    speed = yml['speed'] ? yml['speed'].to_i : 65_536
    @pgsql.exec('UPDATE campaign SET speed=$1 WHERE id=$2', [speed, @id])
    @hash = {}
  end

  def active?
    (@hash['active'] || @pgsql.exec('SELECT active FROM campaign WHERE id=$1', [@id])[0]['active']) == 't'
  end

  def exhausted?
    !(@hash['exhausted'] || @pgsql.exec('SELECT exhausted FROM campaign WHERE id=$1', [@id])[0]['exhausted']).nil?
  end

  def toggle
    @pgsql.exec('UPDATE campaign SET active=not(active) WHERE id=$1', [@id])
    @hash = {}
  end

  def created
    Time.parse(
      @hash['created'] || @pgsql.exec('SELECT created FROM campaign WHERE id=$1', [@id])[0]['created']
    )
  end

  def merge_into(target)
    @pgsql.connect do |c|
      c.transaction do |con|
        con.exec_params('UPDATE source SET campaign = $1 WHERE campaign = $2', [target.id, @id])
        con.exec_params('UPDATE delivery SET campaign = $1 WHERE campaign = $2', [target.id, @id])
        con.exec_params('DELETE FROM campaign WHERE id = $1', [@id])
      end
    end
    @hash = {}
  end

  def deliveries(limit: 50)
    q = [
      'SELECT * FROM delivery',
      'WHERE campaign = $1',
      'ORDER BY delivery.created DESC',
      'LIMIT $2'
    ].join(' ')
    @pgsql.exec(q, [@id, limit]).map do |r|
      Delivery.new(id: r['id'].to_i, pgsql: @pgsql, hash: r)
    end
  end

  def deliveries_count(days: -1)
    @pgsql.exec(
      [
        'SELECT COUNT(*) FROM delivery',
        'WHERE campaign=$1',
        days.positive? ? "AND delivery.created > NOW() - INTERVAL '#{days} DAYS'" : ''
      ].join(' '),
      [@id]
    )[0]['count'].to_i
  end

  def recipients_count
    @pgsql.exec(
      'SELECT COUNT(*) FROM recipient JOIN source ON source.list = recipient.list WHERE source.campaign=$1',
      [@id]
    )[0]['count'].to_i
  end

  def pipeline
    @pgsql.exec(Pipeline.query(@id))
  end

  def pipeline_count
    @pgsql.exec('SELECT COUNT(*) FROM (' + Pipeline.query(@id) + ') x')[0]['count'].to_i
  end
end
