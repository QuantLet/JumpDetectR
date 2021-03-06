## install and load packages ##
libraries = c("data.table")
lapply(libraries, function(x) if (!(x %in% installed.packages())) {install.packages(x)} )
invisible(lapply(libraries, library, quietly = TRUE, character.only = TRUE))
## ##

## settings ##
Sys.setenv(LANG = "en") # set environment language to English
Sys.setlocale("LC_TIME", "en_US.UTF-8") # set timestamp language to English
## ##

LM_JumpTest <-function(DATA, variation_estimate = "Jacod_10"){
  
  # throw out non high frequency data
  #if(nrow(DATA) < 86400*0.75/15) return(data.table())
  
  # preprocess data #
  DT_ts_p <- DATA
  # DT_ts_p[, h := hour(t)] # add hour indicator
  DT_ts_p[, count := 1:nrow(DT_ts_p)] # add index
  
  # extract ID if available
  id_dummy <- NA
  if ("id" %in% names(DT_ts_p)) {id_dummy <- DT_ts_p[,id][1]}
  
  # P tilde
  P_tilde <- log(DT_ts_p[,p])
  
  # Get n
  n <- length(P_tilde)
  T_large <- length(unique(DT_ts_p$date))
  
  # acf #
  bacf <- acf(DT_ts_p[!is.na(log_ret)]$log_ret, plot = FALSE)
  bacfdf <- with(bacf, data.frame(lag, acf))
  
  # CI # https://stackoverflow.com/questions/42753017/adding-confidence-intervals-to-plotted-acf-in-ggplot2
  alpha <- 0.999
  conf.lims <- c(-1,1)*qnorm((1 + alpha)/2)/sqrt(bacf$n.used)
  ##
  lag_outside_conf.lim <- sort(c(which(bacfdf$acf < conf.lims[1]), which(bacfdf$acf > conf.lims[2])))
  
  # Specify k = maximum lag value + 1 
  k <- max(lag_outside_conf.lim) + 1
  if (k == -Inf) {k <- 1} # if no autocorrelation detected
  # if (n>=86400 & k > 10) {k <- 10}
  # if (n==86400/5 & k > 5) {k <- 5}
  # if (n==86400/15 & k > 3) {k <- 3}
  
  # Get n-k
  n_diff <- n - k
  
  # Vector with P_tilde_m+k values
  P_tilde_shift <- shift(P_tilde, n = k, type = "lead")
  
  # Calculate q hat
  q_hat <- sqrt(1/(2 * n_diff) * sum((P_tilde[1:n_diff] - P_tilde_shift[1:n_diff])^2)) # *100 for percentage value (but this will cause trouble in further calculations)
  
  # block size #
  C <- NaN
  if (q_hat * 100 < 0.01) {C <- 1/19;
  print(paste(id_dummy,DT_ts_p[, "s"][1],DT_ts_p[, "date"][1],
              "Q_Hat is smaller than 0.01. C defaulted to 1/19. Choose better value.",
              sep = " - "))
  } else if (q_hat * 100 <= (0.05 + 0.07)/2) {C <- 1/19
  } else if (q_hat * 100 <= (0.1 + 0.2)/2) {C <- 1/18
  } else if (q_hat * 100 <= (0.3 + 0.4)/2) {C <- 1/16
  } else if (q_hat * 100 <= (0.9 + 0.8)/2) {C <- 1/9
  } else if (q_hat * 100 <= 1) {C <- 1/8
  } else if (q_hat * 100 > 1) {C <- 1/8; print(paste(id_dummy,DT_ts_p[, "s"][1],DT_ts_p[, "date"][1],
                                                     "Q_Hat is larger than 1. C defaulted to 1/8. Choose better value.",
                                                     sep = " - "))
  } 
  
  if (C*sqrt(floor(n/k)) < 1) {M <- 1
  } else {
    M <- C*sqrt(floor(n/k))}
  
  
  # Calculate P_hat_tj (first iteration)
  G_n_k <- seq(from = 1, to = n, by = k) # Grid for first subsampling
  G_n_k <- c(G_n_k, n)
  G_n_kM <- seq(from = 1, to = n, by = k*M) # Grid for second subsampling
  G_n_kM <- c(G_n_kM, n) # append last row
  P_tilde_t_ik <- P_tilde[G_n_k]
  
  # Calculate P_hat_tj (second iteration) #
  
  # preallocate
  P_hat_tj <- array(dim = (length(G_n_k))) 
  
  # calculate averages of P_tilde_t_ik over non-overlapping blocks
  for (i in G_n_kM) P_hat_tj[[i]] <- mean(P_tilde_t_ik[(floor(i/k)):(floor(i/k)+M-1)], na.rm = T) 
  if ((floor(1/k)+M-1) < 1) {P_hat_tj[[1]] <- P_tilde_t_ik[1]} # do this if first block goes from 0 to 0
  
  # keep only those times t_j where they lie in the grid G_n_kM
  P_hat_tj  <- P_hat_tj[G_n_kM]
  
  # Calculate L_tj #
  L_tj <- c(0,diff(P_hat_tj))
  shift(P_hat_tj, 1, type = "lead") - P_hat_tj
  
  # Calculate limit #
  V_n <- var(sqrt(M)*L_tj)

  if (variation_estimate == "AJ_09"){
  
    ## Calculate sigma_hat according to Ait-Sahalia & Jacod (2009) "Jump Activity" ##
    sigma_hat <- AJ_09_variation(DT_ts_p)
  
    
  } else if (variation_estimate == "HP_13"){
    ## Calculate sigma_hat according to Hautsch & Podolskij (2013) "Modulated realized covariance" ##
    sigma_hat <-  highfrequency::rMRC(xts(DT_ts_p[,p], order.by = DT_ts_p[,t]))
  } else if (variation_estimate == "Jacod_10"){
    ## Calculate sigma_hat according to Jacod et al. (2010) "Pre-averaging" ##
    sigma_hat <-  jacod_preaveraging(DT_ts_p)
  }
  
  plimVn <- 2/3 * sigma_hat^2 * C^2 * T_large + 2 * q_hat^2

  # Calculate Chi_tj
  Chi_tj <- sqrt(M) / sqrt(plimVn) * L_tj
  
  # Define A_n & B_n
  logpernkM <- log(floor(n/(k*M)))
  An <- sqrt(2*logpernkM)  - (log(pi)+log(logpernkM))/(2*sqrt(2*logpernkM))
  Bn <- 1 / (sqrt(2 * logpernkM))
  
  # Jump threshold
  significance_level <- 0.01
  beta_star   <-  -log(-log(1-significance_level)) 
  critical_value <- beta_star*Bn + An # Jump threshold
  
  J   <-  as.numeric(abs(Chi_tj) > critical_value) # Test threshold
  J   <-  J*sign(Chi_tj) # Add direction
  
  
  # aggregate results in data.table
  res <- data.table("t" = DT_ts_p[,t][G_n_kM],
                    "date" =  DT_ts_p[,date][1],
                    "id" =  id_dummy,
                    "s" =  DT_ts_p[,s][1],
                    "count" = DT_ts_p[,count][G_n_kM], 
                    "P_hat_tj" = P_hat_tj,
                    "exp_P_hat_tj" = exp(P_hat_tj),
                    "exp_P_hat_tj_minus1" = shift(exp(P_hat_tj), 1, type = "lag"),
                    "k" = k,
                    "M" = M,
                    "kM" = k*M,
                    "C" = C,
                    "qhat" = q_hat,
                    "sigmahat" = sigma_hat,
                    "Vn" = V_n,
                    "plim_Vn" = plimVn,
                    "A_n" = An,
                    "B_n" = Bn)
  res[,`:=` ('L_t_j' = L_tj,
             'Chi_t_j' = Chi_tj,
             'sign_level' = significance_level,
             'betastar' = beta_star,
             'criticalvalue' = critical_value,
             'Jump_indicator' = J)]
  
  return(res)
}
