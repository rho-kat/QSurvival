

#' Convert hazard to survival function and instantaneous
#' event intensities.
#'
#' Sums up hazard function grouped by original ID variable ordered by step.
#'
#' @param d data.frame
#' @param idColumnName character scalar, column containing original row ids
#' @param indexColumnName character scalar, column containing quasi event indices. Indices must be complete intevvals 1:k for some k.
#' @param hazardColumnNames character vector, columns containing hazard scores
#' @param survivalColumnNames character vector, columns to write survival probability in
#' @param deathIntensityColumnNames vector scalar, columns to write death intensities
#' @param parallelCluster optional parallel cluster to run on
#' @return list, details=survival data.frame, expectedLifetime has lifetime estimates (lifetime seen in the scoring windows plus a geometric term to count time steps past the window).
#'
#' @examples
#'
#' d <- data.frame(lifetime=c(2,1,2),censored=c(FALSE,FALSE,TRUE))
#' d2 <- buildQuasiObsForComparison(d,5,d$lifetime,ifelse(d$censored,NA,d$lifetime),
#'    'origRow','sampleAge','deathEvent')
#' d2$hazardPred <- 0.1
#' summarizeHazard(d2,'origRow','sampleAge','hazardPred',
#'    survivalColumnName='survival',
#'    deathIntensityColumnName='deathIntensity')
#'
#'
#' @importFrom dplyr bind_rows
#' @export
summarizeHazard <- function(d,idColumnName,indexColumnName,
                            hazardColumnNames,
                            survivalColumnNames='survival',
                            deathIntensityColumnNames=NULL,
                            parallelCluster=NULL) {
  if(!("data.frame" %in% class(d))) {
    stop("summarizeHazard d must be a data.frame")
  }
  if(!(idColumnName %in% colnames(d))) {
    stop("summarizeHarard must have idColumnName in data frame")
  }
  if(!(indexColumnName %in% colnames(d))) {
    stop("summarizeHarard must have indexColumnName in data frame")
  }
  if(!all(hazardColumnNames %in% colnames(d))) {
    stop("summarizeHarard must have hazardColumnNames in data frame")
  }
  if(length(hazardColumnNames)!=length(survivalColumnNames)) {
    stop('summarizeHazard must have length(hazardColumnNames)==length(survivalColumnNames)')
  }
  if(min(d[,hazardColumnNames])<0) {
    stop('summarizeHazard must have non-negative hazard')
  }
  if(max(d[,hazardColumnNames])>1) {
    stop('summarizeHazard must have hazard <=1')
  }
  if(any(is.na(d[,hazardColumnNames]))) {
    stop('summaryHazard can not have NA in hazard')
  }
  if((!is.null(deathIntensityColumnNames))&&
     (length(hazardColumnNames)!=length(deathIntensityColumnNames))) {
    stop('summarizeHazard must have length(hazardColumnNames)==length(deathIntensityColumnNames)')
  }
  dlist <- split(d,d[[idColumnName]])
  mkWorker <- function(idColumnName,
                       indexColumnName,
                       hazardColumnNames,
                       survivalColumnNames,
                       deathIntensityColumnNames) {
    force(idColumnName)
    force(indexColumnName)
    force(hazardColumnNames)
    force(survivalColumnNames)
    force(deathIntensityColumnNames)
    function(di) {
      # need di to be ordered 1:k for some k>=1
      dii <-di[[indexColumnName]]
      if((min(dii)<1)||(max(dii)>length(dii))||
         (any(sort(dii)!=seq_len(length(dii))))) {
          stop("QSurvive::summarizeHazard timesteps must be 1:k intervals")
      }
      di <- di[order(dii),]
      for(j in seq_len(length(hazardColumnNames))) {
        scn <- survivalColumnNames[[j]]
        hcn <- hazardColumnNames[[j]]
        di[[scn]] <- cumprod(pmax(0,1-pmin(1,di[[hcn]])))
        before <- c(1,di[[scn]])
        before <- before[-length(before)]
        if(!is.null(deathIntensityColumnNames)) {
          din <- deathIntensityColumnNames[[j]]
          di[[din]] <-  before - di[[scn]]
        }
      }
      di
    }
  }
  worker <- mkWorker(idColumnName,
                     indexColumnName,
                     hazardColumnNames,
                     survivalColumnNames,
                     deathIntensityColumnNames)
  if(is.null(parallelCluster) || (!requireNamespace("parallel",quietly=TRUE))) {
    dlist <- lapply(dlist,worker)
  } else {
    dlist <- parallel::parLapply(parallelCluster,dlist,worker)
  }
  dH <- as.data.frame(dplyr::bind_rows(dlist),stringsAsFactors=FALSE)
  expectedLifetimes <- lapply(dlist,
                              function(di) {
                                ri <- data.frame(di[1,idColumnName],
                                                 stringsAsFactors = FALSE)
                                colnames(ri) <- idColumnName
                                ni <- nrow(di)
                                for(j in seq_len(length(survivalColumnNames))) {
                                  hcn <- hazardColumnNames[[j]]
                                  scn <- survivalColumnNames[[j]]
                                  residualExpectation <- 0.0
                                  if(di[ni,hcn]>0) {
                                    # expected lifetime after window geometric model
                                    residualExpectation <- di[ni,scn]/di[ni,hcn]
                                  }
                                  ri[[scn]] <- sum(di[[scn]]) + residualExpectation
                                }
                                ri
                              })
  expectedLifetime <- as.data.frame(dplyr::bind_rows(expectedLifetimes),stringsAsFactors=FALSE)
  list(details=dH,expectedLifetime=expectedLifetime)
}

#' Calculate what fraction of ages are below each threshold. Do NOT use this on censored data (as all ages are interpreted as end).
#'
#' @param ages numeric vector non-negative with integer values
#' @param range integer scalar integer posotive range to calculate to
#' @return data frame with fraction less than our equal to each value
#'
#' @examples
#'
#' summarizeActual(1:5,7)
#'
#' @export
summarizeActual <- function(ages,range) {
  if(min(ages)<0) {
    stop('summarizeActual ages must be non-negative')
  }
  if(range<=0) {
    stop('summarizeActual range must be positive')
  }
  ages <- as.data.frame(table(age=as.character(ages)))
  ages$age <- as.numeric(as.character(ages$age))
  ages <- ages[order(ages$age),]
  tot <- sum(ages$Freq)
  res <- data.frame(age=0:range)
  count <- numeric(range+1)
  count[ages$age+1] <- ages$Freq
  data.frame(age=0:range,count=(tot - cumsum(count))/tot,stringsAsFactors=FALSE)
}

#' Build observed survival curves for a frame.  Do NOT use this on censored data (as all ages are interpreted as end).
#'
#' @param d data.frame
#' @param groupColumnName name of grouping column
#' @param ageColumnName name of age column
#' @param parallelCluster optional parallel cluster to run on
#' @return survival curves
#'
#' @examples
#'
#' s <- summarizeActualFrame(data.frame(age=1:10,
#'                                      group=as.factor((1:10)%%2)),
#'    'group','age')
#' # ggplot() + geom_line(data=s,mapping=aes(x=age,y=survival,color=group))
#'
#' @export
summarizeActualFrame <- function(d,groupColumnName,ageColumnName,
                                 parallelCluster=NULL) {
  if(!("data.frame" %in% class(d))) {
    stop("summarizeActualFrame d must be a data.frame")
  }
  if(!(groupColumnName %in% colnames(d))) {
    stop("summarizeActualFrame must have groupColumnName in data frame")
  }
  if(!(ageColumnName %in% colnames(d))) {
    stop("summarizeActualFrame must have ageColumnName in data frame")
  }
  range <- max(d[[ageColumnName]])
  dlist <- split(d,d[[groupColumnName]])
  mkWorker <- function(groupColumnName,ageColumnName) {
    force(groupColumnName)
    force(ageColumnName)
    function(di) {
      ri <- summarizeActual(di[[ageColumnName]],range)
      colnames(ri) <- c(ageColumnName,'survival')
      ri[[groupColumnName]] <- di[1,groupColumnName]
      ri
    }
  }
  worker <- mkWorker(groupColumnName,ageColumnName)
  if(is.null(parallelCluster) || (!requireNamespace("parallel",quietly=TRUE))) {
    reslist <- lapply(dlist,worker)
  } else {
    reslist <- parallel::parLapply(parallelCluster,dlist,worker)
  }
  res <- dplyr::bind_rows(reslist)
  as.data.frame(res,stringsAsFactors=FALSE)
}