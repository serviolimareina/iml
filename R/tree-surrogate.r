#' Decision tree surrogate model
#' 
#' @description 
#' Fit a decision tree model on another machine learning models predictions to replace or explain the other model.
#' 
#' @details  
#' A conditional inference tree is fitted on the predicted \eqn{\hat{y}} from the machine learning model and the data \eqn{X}.
#' The \code{partykit} package and function are used to fit the tree. 
#' By default a tree of maximum depth of 2 is fitted to improve interpretability.
#' 
#' @return 
#' A decision tree surrogate object
#' @template args_experiment_wrap
#' @template arg_sample.size
#' @return
#' \itemize{
#' \item \code{obj$predict(newdata)} can be used to get predictions from the decision tree
#' }
#' @examples 
#' library("randomForest")
#' data("Boston", package  = "MASS")
#' mod = randomForest(medv ~ ., data = Boston, ntree = 50)
#' 
#' # Fit a decision tree as a surrogate for the whole random forest
#' dt = tree.surrogate(mod, Boston[-which(names(Boston) == 'medv')], 200)
#' 
#' # Plot the resulting leaf nodes
#' plot(dt) 
#' 
#' # Use the tree to predict new data
#' predict(dt, Boston[1:10,])
#' 
#' # Extract the dataset
#' dat = tree$data()
#' head(dat)
#' 
#' 
#' # It also works for classification
#' mod = randomForest(Species ~ ., data = iris, ntree = 50)
#' 
#' # Fit a decision tree as a surrogate for the whole random forest
#' X = iris[-which(names(iris) == 'Species')]
#' dt = tree.surrogate(mod, X, 200, predict.args = list(type = 'prob'), tree.args = list(maxdepth = 1))
#'
#' # Plot the resulting leaf nodes
#' plot(dt) 
#' 
#' # Use the tree to predict new data
#' set.seed(42)
#' iris.sample = X[sample(1:nrow(X), 10),]
#' predict(dt, iris.sample)
#' predict(dt, iris.sample, type = 'class')

#' # Extract the dataset
#' dat = tree$data()
#' head(dat)
#'
#' @param tree.args A list with further arguments for \code{ctree}
#' @importFrom partykit ctree
#' @export
tree.surrogate = function(object, X, sample.size=100, class = NULL, tree.args = list(maxdepth=2), ...){
  samp = DataSampler$new(X)
  pred = prediction.model(object, class = class, ...)
  
  TreeSurrogate$new(predictor = pred, sampler = samp, sample.size = sample.size, tree.args = tree.args)$run()
}

#' @export
predict.TreeSurrogate = function(object, newdata, ...){
  object$predict(newdata = newdata, ...)
}

## Craven, M. W., & Shavlik, J. W. (1996).
## Extracting tree-structured representations of trained neural networks.
## Advances in Neural Information Processing Systems, 8, 24–30.
## Retrieved from citeseer.ist.psu.edu/craven96extracting.html
TreeSurrogate = R6::R6Class('TreeSurrogate',
  inherit = Experiment,
  public = list(
    summary = function(){
      self$run()
      summary(private$results)
    },
    initialize = function(predictor, sampler, sample.size, tree.args){
      super$initialize(predictor, sampler)
      self$sample.size = sample.size
      private$tree.args = tree.args
    }, 
    predict = function(newdata, type = 'prob'){
      assert_choice(type, c('prob', 'class'))
      res = data.frame(predict(private$model, newdata = newdata, type = 'response'))
      if(private$multi.class){
        if(type == 'class') {
          res = data.frame(..class = colnames(res)[apply(res, 1, which.max)])
        }
      } else {
        res = data.frame(..y.hat = predict(private$model, newdata = newdata))
      }
      res
    }
  ), 
  private = list(
    model = NULL, 
    tree.args = NULL,
    # Only relevant in multi.class case
    tree.predict.colnames = NULL,
    # Only relevant in multi.class case
    object.predict.colnames = NULL,
    intervene = function(){private$X.sample},
    aggregate = function(){
      y.hat = private$Q.results
      if(private$multi.class){
        classes = colnames(y.hat)
        form = formula(sprintf("%s ~ .", paste(classes, collapse = "+")))       
      } else {
        y.hat = unlist(y.hat[1])
        form = y.hat ~ .
      }
      dat = cbind(y.hat, private$X.design)
      tree.args = c(list(formula = form, data = dat), private$tree.args)
      private$model = do.call(partykit::ctree, tree.args)
      result = data.frame(..node = predict(private$model, type = 'node'), 
        ..path = pathpred(private$model))
      if(private$multi.class){
        outcome = private$Q.results
        colnames(outcome) = paste('..y.hat:', colnames(outcome), sep='')
        private$object.predict.colnames = colnames(outcome)

        # result = gather(result, key = "..class", value = "..y.hat", one_of(cnames))
        ..y.hat.tree = self$predict(private$X.design, type = 'prob')
        colnames(..y.hat.tree) = paste('..y.hat.tree:', colnames(..y.hat.tree), sep='')
        private$tree.predict.colnames = colnames(..y.hat.tree)

        #..y.hat.tree = gather(..y.hat.tree, '..class.tree', '..y.hat.tree')
        result = cbind(result, outcome, ..y.hat.tree)
        } else {
        result$..y.hat = private$Q.results[[1]]
        result$..y.hat.tree = self$predict(private$X.design)[[1]]
      }
      design = private$X.design
      rownames(design) = NULL
      cbind(design, result)
    }, 
    generate.plot = function(){
      p = ggplot(private$results) + 
        geom_boxplot(aes(y = ..y.hat, x = "")) + 
        scale_x_discrete('') + 
        facet_wrap("..path")
      if(private$multi.class){
        plot.data = private$results
        # max class for model
        plot.data$..class = private$object.predict.colnames[apply(plot.data[private$object.predict.colnames], 1, which.max)]
        plot.data$..class = gsub('..y.hat:', '', plot.data$..class)
        plot.data = plot.data[setdiff(names(plot.data), private$object.predict.colnames)]
        # dataset from wide to long
        plot.data.l = gather(plot.data, '..tree.class', '..class.prob', one_of(private$tree.predict.colnames))
        plot.data.l$..tree.class = gsub('..y.hat.tree:', '', plot.data.l$..tree.class)  
        p = ggplot(plot.data.l) + 
          geom_boxplot(aes(y = ..class.prob, x = ..class)) + 
          facet_wrap("..path")
      }
      p
    }
    
  )
)


pathpred <- function(object, ...)
{
  ## coerce to "party" object if necessary
  if(!inherits(object, "party")) object = as.party(object)
  
  
  ## get rules for each node
  rls = partykit:::.list.rules.party(object)
  
  ## get predicted node and select corresponding rule
  rules = rls[as.character(predict(object, type = "node", ...))]
  rules = gsub("&", "&\n", rules)
  
  return(rules)
}
