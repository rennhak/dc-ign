require 'sys'
require 'xlua'
require 'torch'
require 'nn'
require 'rmsprop'

require 'KLDCriterion'

require 'LinearCR'
require 'Reparametrize'
require 'cutorch'
require 'cunn'
require 'optim' 


----------------------------------------------------------------------
-- parse command-line options
--
local opt = lapp[[
   -s,--save          (default "logs")      subdirectory to save logs
   -n,--network       (default "")          reload pretrained network
   -m,--model         (default "convnet")   type of model tor train: convnet | mlp | linear
   -p,--plot                                plot while training
   -o,--optimization  (default "SGD")       optimization: SGD | LBFGS 
   -r,--learningRate  (default 0.05)        learning rate, for SGD only
   -m,--momentum      (default 0)           momentum, for SGD only
   -i,--maxIter       (default 3)           maximum nb of iterations per batch, for LBFGS
   --coefL1           (default 0)           L1 penalty on the weights
   --coefL2           (default 0)           L2 penalty on the weights
   -t,--threads       (default 4)           number of threads
   --dumpTest                                preloads model and dumps .mat for test
   -d,--datasrc       (default "")          data source directory
   -f,--fbmat         (default 0)           load fb.mattorch       
]]

if opt.fbmat == 1 then
  mattorch = require('fb.mattorch')
else
  require 'mattorch'
end

-- threads
torch.setnumthreads(opt.threads)
print('<torch> set nb of threads to ' .. torch.getnumthreads())

opt.cuda = true

torch.manualSeed(1)

bsize = 50
imwidth = 150

TOTALFACES = 1000--5230
num_train_batches = 950--5000
num_test_batches =  TOTALFACES-num_train_batches

function load_batch(id, mode)
  return torch.load('DATASET/th_' .. mode .. '/batch' .. id)
end

function init_network()
 -- Model Specific parameters
  filter_size = 5
  dim_hidden = 30*2
  input_size = 32*2
  pad1 = 2
  pad2 = 2
  colorchannels = 1
  total_output_size = colorchannels * input_size ^ 2
  feature_maps = 16*2
  hidden_dec = 25*2
  map_size = 16*2
  factor = 2
  encoder = nn.Sequential()
  encoder:add(nn.SpatialZeroPadding(pad1,pad2,pad1,pad2))
  encoder:add(nn.SpatialConvolutionMM(colorchannels,feature_maps,filter_size,filter_size))
  encoder:add(nn.SpatialMaxPooling(2,2,2,2))
  encoder:add(nn.Threshold(0,1e-6))
  encoder:add(nn.Reshape(feature_maps * map_size * map_size))
  local z = nn.ConcatTable()
  z:add(nn.LinearCR(feature_maps * map_size * map_size, dim_hidden))
  z:add(nn.LinearCR(feature_maps * map_size * map_size, dim_hidden))
  encoder:add(z)
  local decoder = nn.Sequential()
  decoder:add(nn.LinearCR(dim_hidden, feature_maps * map_size * map_size))
  decoder:add(nn.Threshold(0,1e-6))
  --Reshape and transpose in order to upscale
  decoder:add(nn.Reshape(bsize, feature_maps, map_size, map_size))
  decoder:add(nn.Transpose({2,3},{3,4}))
  --Reshape and compute upscale with hidden dimensions
  decoder:add(nn.Reshape(map_size * map_size * bsize, feature_maps))
  decoder:add(nn.LinearCR(feature_maps,hidden_dec))
  decoder:add(nn.Threshold(0,1e-6))
  decoder:add(nn.LinearCR(hidden_dec,colorchannels*factor*factor))
  decoder:add(nn.Sigmoid())
  decoder:add(nn.Reshape(bsize,1,input_size,input_size))

  model = nn.Sequential()
  model:add(encoder)
  model:add(nn.Reparametrize(dim_hidden))
  model:add(decoder)
    
  model:cuda()  
  collectgarbage()
  return model
end


model = init_network()


if continuous then
    criterion = nn.GaussianCriterion()
else
    criterion = nn.BCECriterion()
    criterion.sizeAverage = false
end

KLD = nn.KLDCriterion()
KLD.sizeAverage = false

if opt.cuda then
    criterion:cuda()
    KLD:cuda()
    model:cuda()
end


parameters, gradients = model:getParameters()

config = {
    learningRate = -0.001,
    momentumDecay = 0.1,
    updateDecay = 0.01
}

function getLowerbound(data)
    local lowerbound = 0
    N_data = data:size(1) - (data:size(1) % batchSize)
    for i = 1, N_data, batchSize do
        local batch = data[{{i,i+batchSize-1},{}}]
        local f = model:forward(batch)
        local target = target or batch.new()
        target:resizeAs(f):copy(batch)
        local err = - criterion:forward(f, target)

        local encoder_output = model:get(1).output

        local KLDerr = KLD:forward(encoder_output, target)

        lowerbound = lowerbound + err + KLDerr
    end
    return lowerbound
end


if opt.continue == true then 
    print("Loading old weights!")
    lowerboundlist = torch.load(opt.save ..        '/lowerbound.t7')
    lowerbound_test_list =  torch.load(opt.save .. '/lowerbound_test.t7')
    state = torch.load(opt.save .. '/state.t7')
    p = torch.load(opt.save .. '/parameters.t7')

    parameters:copy(p)

    epoch = lowerboundlist:size(1)
else
    epoch = 0
    state = {}
end

testLogger = optim.Logger(paths.concat(opt.save, 'test.log'))
reconstruction = 0

-- test function
function testf()
   -- local vars
   local time = sys.clock()
   -- test over given dataset
   print('<trainer> on testing Set:')
   reconstruction = 0

   for t = 1,num_test_batches do
      -- create mini batch
      local raw_inputs = load_batch(t, 'test')
      local targets = raw_inputs

      inputs = raw_inputs:cuda()
      -- disp progress
      xlua.progress(t, num_test_batches)

      -- test samples
      local preds = model:forward(inputs)
      preds = preds:float()

      reconstruction = reconstruction + torch.sum(torch.pow(preds-targets,2))
      
      if t == 1 then
        torch.save('tmp/preds', preds)
      end
   end
   -- timing
   time = sys.clock() - time
   time = time / num_test_batches
   print("<trainer> time to test 1 sample = " .. (time*1000) .. 'ms')

   -- print confusion matrix
   reconstruction = reconstruction / (bsize * num_test_batches * 3 * 150 * 150)
   print('mean MSE error (test set)', reconstruction)
   testLogger:add{['% mean class accuracy (test set)'] = reconstruction}
   reconstruction = 0
end


while true do
    epoch = epoch + 1
    local lowerbound = 0
    local time = sys.clock()

    for i = 1,num_train_batches do
        xlua.progress(i, num_train_batches)

        --Prepare Batch
        local batch = load_batch(i,'training')
      
         if opt.cuda then
            batch = batch:cuda()
        end 

        --Optimization function
        local opfunc = function(x)
            collectgarbage()

            if x ~= parameters then
                parameters:copy(x)
            end

            model:zeroGradParameters()
            local f = model:forward(batch)

            local target = target or batch.new()
            target:resizeAs(f):copy(batch)

            local err = - criterion:forward(f, target)
            local df_dw = criterion:backward(f, target):mul(-1)

            model:backward(batch,df_dw)
            local encoder_output = model:get(1).output

            local KLDerr = KLD:forward(encoder_output, target)
            local dKLD_dw = KLD:backward(encoder_output, target)

            encoder:backward(batch,dKLD_dw)

            local lowerbound = err  + KLDerr

            if opt.verbose then
                print("BCE",err/batch:size(1))
                print("KLD", KLDerr/batch:size(1))
                print("lowerbound", lowerbound/batch:size(1))
            end

            return lowerbound, gradients 
        end

        x, batchlowerbound = rmsprop(opfunc, parameters, config, state)

        lowerbound = lowerbound + batchlowerbound[1]
    end

    print("Epoch: " .. epoch .. " Lowerbound: " .. lowerbound/num_train_batches .. " time: " .. sys.clock() - time)

    --Keep track of the lowerbound over time
    if lowerboundlist then
        lowerboundlist = torch.cat(lowerboundlist,torch.Tensor(1,1):fill(lowerbound/num_train_batches),1)
    else
        lowerboundlist = torch.Tensor(1,1):fill(lowerbound/num_train_batches)
    end

    testf()
    --Compute the lowerbound of the test set and save it
    -- if epoch % 2 == 0 then
    --     lowerbound_test = getLowerbound(testData.data)

    --      if lowerbound_test_list then
    --         lowerbound_test_list = torch.cat(lowerbound_test_list,torch.Tensor(1,1):fill(lowerbound_test/num_test_batches),1)
    --     else
    --         lowerbound_test_list = torch.Tensor(1,1):fill(lowerbound_test/num_test_batches)
    --     end

    --     print('testlowerbound = ' .. lowerbound_test/num_test_batches)

    --     --Save everything to be able to restart later
    --     torch.save(opt.save .. '/parameters.t7', parameters)
    --     torch.save(opt.save .. '/state.t7', state)
    --     torch.save(opt.save .. '/lowerbound.t7', torch.Tensor(lowerboundlist))
    --     torch.save(opt.save .. '/lowerbound_test.t7', torch.Tensor(lowerbound_test_list))
    -- end
end
