class FetchController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authenticate_key
  layout false

  ### old api

  def interlib
    @problem = Problem.find(params[:pid])
    @interlib = @problem.interlib.to_s + "\n"
    render plain: @interlib
  end

  def sjcode
    @problem = Problem.find(params[:pid])
    @sjcode = @problem.sjcode.to_s
    render plain: @sjcode
  end

  def code
    @submission = Submission.find(params[:sid])
    @code = @submission.code.to_s
    render plain: @code
  end

  def testdata_meta
    @problem = Problem.find(params[:pid])
    @result = @problem.testdata.count.to_s + " "
    @problem.testdata.order(position: :asc).each do |t|
      @result += t.id.to_s + " "
      @result += t.updated_at.to_i.to_s + "\n"
    end
    render plain: @result
  end

  def testdata_limit
    @problem = Problem.find(params[:pid])
    @result = ""
    @problem.testdata.order(position: :asc).includes(:limit).each do |t|
      @result += t.limit.time.to_s + " "
      @result += t.limit.memory.to_s + " "
      @result += t.limit.output.to_s + "\n"
    end
    render plain: @result
  end

  def write_result
    @_result = params[:result]
    @submission = Submission.find(params[:sid])
    if @_result == "CE"
      @submission.update(:result => "CE", :score => 0)
    elsif @_result == "ER"
      @submission.update(:result => "ER", :score => 0)
    else
      update_verdict
    end
  end

  def write_message
    @_message = params[:message]
    @submission = Submission.find(params[:sid])
    @submission.update(:message => @_message)
    #logger.info @_message
  end

  def update_verdict
    #score
    @_result = @_result.split("/").each_slice(3).map.with_index { |res, id|
      {:submission_id => @submission.id, :position => id, :result => res[0],
       :time => res[1].to_i, :memory => res[2].to_i,
       :score => res[0] == 'AC' ? 100 : 0}
    }.select{|x| x[:result] != ''}
    SubmissionTask.import(@_result, on_duplicate_key_update: [:result, :time, :memory, :score])
    @problem = @submission.problem
    num_tasks = @problem.testdata.count
    @score = @problem.testdata_sets.map{|s|
      lst = td_list_to_arr(s.td_list, num_tasks)
      set_result = @_result.values_at(*lst)
      set_result.all? ? (lst.size > 0 ? set_result.map{|x| x[:score]}.min : 100) * s.score : 0
    }.sum / 100
    @score = [@score, BigDecimal('1e+12') - 1].min.round(6)
    @submission.update(:score => @score)

    #verdict
    if params[:status] == "OK"
      ttime = @_result.map{|i| i[:time]}.sum
      tmem = @_result.map{|i| i[:memory]}.max
      @result = @_result.map{|i| @v2i[i[:result]] ? @v2i[i[:result]] : 9}.max
      @submission.update(:result => @i2v[@result], :total_time => ttime, :total_memory => tmem)
    end
  end

  def validating
    @submission = Submission.find(params[:sid])
    @submission.update(:result => "Validating")
  end

  def submission
    Submission.transaction do
      @submission = Submission.lock.where("`result` = 'queued' AND `contest_id` IS NOT NULL").order('id').first
      if not @submission
        @submission = Submission.lock.where("`result` = 'queued'").order('id').first
      end
      if @submission
        @submission.update(:result => "received")
      end
    end
    #@submission = Submission.where("`result` = 'queued' AND `contest_id` IS NULL").order('id desc').first
    #if not @submission
    #  @submission = Submission.where("`result` = 'queued'").order('id desc').first
    #end
    if @submission
      @result = @submission.id.to_s
      @result += "\n"
      @result += @submission.problem_id.to_s
      @result += "\n"
      @result += @submission.problem.problem_type.to_s
      @result += "\n"
      @result += @submission.user_id.to_s
      @result += "\n"
      @result += @submission.compiler.name.to_s
      @result += "\n"
    else
      @result = "-1\n"
    end
    render plain: @result
  end

  ### both old and new api
  def testdata
    @testdata = Testdatum.find(params[:tid])
    if params[:input]
      @path = @testdata.test_input
    else
      @path = @testdata.test_output
    end
    send_file(@path.to_s)
  end

  ### new api

  def submission_new
    Submission.transaction do
      @submission = Submission.lock.where("`result` = 'queued'").order('contest_id IS NOT NULL ASC', 'id ASC').first
      if @submission
        @submission.update(:result => "received")
      else
        render json: {}
        return
      end
    end
    @problem = @submission.problem
    @user = @submission.user
    td_count = @problem.testdata.count
    render json: {
      submission_id: @submission.id,
      compiler: @submission.compiler.name,
      user: {
        id: @user.id,
        name: @user.username,
        nickname: @user.nickname,
      },
      problem: {
        id: @problem.id,
        type: @problem.problem_type,
        sjcode: @problem.sjcode,
        interlib: @problem.interlib,
      },
      td: @problem.testdata.order(position: :asc).includes(:limit).map { |t|
        {
          id: t.id,
          updated_at: t.updated_at.to_i,
          time: t.limit.time,
          vss: t.limit.memory,
          rss: 0,
          output: t.limit.output,
        }
      },
      tasks: @problem.testdata_sets.map { |s|
        {
          positions: td_list_to_arr(s.td_list, td_count),
          score: (s.score * BigDecimal('1e+6')).to_i,
        }
      },
    }
  end

  def td_result
    @submission = Submission.find(params[:submission_id])
    results = params[:results].map { |res|
      {
        submission_id: @submission.id,
        position: res[:position],
        result: res[:verdict],
        time: res[:time] / 1000,
        memory: res[:rss],
        score: (BigDecimal(res[:score]) / BigDecimal('1e+6')).round(6).clamp(BigDecimal('-1e+6'), BigDecimal('1e+6')),
      }
    }
    SubmissionTask.import(results, on_duplicate_key_update: [:result, :time, :memory, :score])
    score_map = @submission.submission_tasks.map { |t| [t.position, t.score] }.to_h
    @problem = @submission.problem
    num_tasks = @problem.testdata.count
    score = @problem.testdata_sets.map{|s|
      lst = td_list_to_arr(s.td_list, num_tasks)
      set_result = score_map.values_at(*lst)
      set_result.all? ? (lst.size > 0 ? set_result.min : BigDecimal(100)) * s.score : 0
    }.sum / 100
    max_score = BigDecimal('1e+12') - 1
    score = score.clamp(-max_score, max_score).round(6)
    @submission.update(:score => score)
  end

  def submission_result
    @submission = Submission.find(params[:submission_id])
    if params[:verdict] == 'Validating'
      @submission.update(:result => 'Validating')
      return
    end
    update_hash = {}
    if params[:message]
      update_hash[:message] = params[:message]
    end
    update_hash[:result] = @i2v[@v2i.fetch(params[:verdict], @v2i['ER'])]
    if not ['ER', 'CE', 'CLE'].include? update_hash[:verdict]
      tasks = @submission.submission_tasks
      update_hash[:total_time] = tasks.map{|i| i.time}.sum
      update_hash[:total_memory] = tasks.map{|i| i.memory}.max
    end
    @submission.update(**update_hash)
  end

private
  def authenticate_key
    if not params[:key]
      head :unauthorized
      return
    end
    @judge = JudgeServer.find_by(key: params[:key])
    if not @judge or @judge.ip != request.remote_ip
      head :unauthorized
      return
    end
  end
end
