class AltitudeGradientKalman {
    // Process & measurement noise covariances
    var Q;    // 2×2 matrix for process noise
    var R;    // scalar for measurement noise
    
    // State and covariance
    var x;    // 2×1 vector [h; g]
    var P;    // 2×2 covariance matrix

    /**
     * @param initAlt   initial altitude estimate (m)
     * @param initGrad  initial gradient estimate (rise/run)
     * @param processVarAlt   process noise var for altitude (m^2)
     * @param processVarGrad  process noise var for gradient ((rise/run)^2)
     * @param measVarAlt      measurement noise var for altitude (m^2)
     */
    function initialize(initAlt, initGrad, processVarAlt, processVarGrad, measVarAlt) {
        // initial state
        x = [initAlt, initGrad];
        P = [ [processVarAlt, 0.0], [0.0, processVarGrad] ];
        // set Q & R
        Q = [ [processVarAlt, 0.0], [0.0, processVarGrad] ];
        R = measVarAlt;
    }

    /**
     * Run one Kalman predict+update step.
     * @param deltaDist  meters traveled since last update
     * @param measAlt    baro altitude measurement (m)
     * @return           { estAlt:Float, estGrad:Float }
     */
    function update(deltaDist, measAlt) {
        // Build F matrix for this step: [[1, Δd], [0,1]]
        var F = [ [1.0, deltaDist], [0.0, 1.0] ];

        // Predict
        // x_prior = F * x
        var x_prior = [ F[0][0]*x[0] + F[0][1]*x[1], F[1][0]*x[0] + F[1][1]*x[1] ];
        // P_prior = F*P*F^T + Q
        var P_prior = [
            [ 
              F[0][0]*P[0][0]*F[0][0] + F[0][0]*P[0][1]*F[0][1]
            + F[0][1]*P[1][0]*F[0][0] + F[0][1]*P[1][1]*F[0][1]
            + Q[0][0],
              F[0][0]*P[0][0]*F[1][0] + F[0][0]*P[0][1]*F[1][1]
            + F[0][1]*P[1][0]*F[1][0] + F[0][1]*P[1][1]*F[1][1]
            + Q[0][1]
            ],
            [
              F[1][0]*P[0][0]*F[0][0] + F[1][0]*P[0][1]*F[0][1]
            + F[1][1]*P[1][0]*F[0][0] + F[1][1]*P[1][1]*F[0][1]
            + Q[1][0],
              F[1][0]*P[0][0]*F[1][0] + F[1][0]*P[0][1]*F[1][1]
            + F[1][1]*P[1][0]*F[1][0] + F[1][1]*P[1][1]*F[1][1]
            + Q[1][1]
            ]
        ];

        // Compute Kalman gain K = P_prior * H^T * inv(H * P_prior * H^T + R)
        // Here H = [1 0], so H*P_prior*H^T = P_prior[0][0]
        var S = P_prior[0][0] + R;  // innovation covariance
        var K = [
            [ P_prior[0][0] / S ],
            [ P_prior[1][0] / S ]
        ];  // 2×1 gain

        // Update state x = x_prior + K * (z - H*x_prior)
        var y = measAlt - x_prior[0]; // measurement residual
        x = [
            x_prior[0] + K[0][0] * y,
            x_prior[1] + K[1][0] * y
        ];

        // Update covariance P = (I - K*H) * P_prior
        // (I - K*H) = [[1-K00, -K01],[ -K10, 1-K11]] but H has zero second column
        P = [
            [
              (1.0 - K[0][0]) * P_prior[0][0],
              (1.0 - K[0][0]) * P_prior[0][1]
            ],
            [
              -K[1][0] * P_prior[0][0] + P_prior[1][0],
              -K[1][0] * P_prior[0][1] + P_prior[1][1]
            ]
        ];

        // Return estimates
        return {  "estAlt" => x[0],  "estGrad" => x[1] };
    }
}
