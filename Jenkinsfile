// Jamii Savings: ONE pipeline for all three integrations (Accounts, Customers, Loans).
//
// Build MI CAR -> package APIM artifacts -> spin up dev (compose) -> deploy MI -> test MI
//   -> deploy APIM -> test through the gateway -> [approval] -> prod
//
// Every stage calls a script in scripts/ or tests/ so the exact same steps run locally.
// Agent requirements: Linux, bash, docker + compose plugin, JDK 21, python3, curl.

def APIS = ['AccountsAPI', 'CustomersAPI', 'LoansAPI']

pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()          // one deployment at a time per environment
    timeout(time: 45, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '10'))
  }

  parameters {
    booleanParam(name: 'FAULT_TESTS',     defaultValue: false, description: 'Also run DB-down / backend-down fault injection in dev')
    booleanParam(name: 'PROMOTE_TO_PROD', defaultValue: false, description: 'After dev passes, ask for approval and deploy to prod')
    booleanParam(name: 'KEEP_DEV_ENV',    defaultValue: false, description: 'Leave the dev compose stack running after the build')
  }

  environment {
    COMPOSE_PROJECT_NAME = 'jamiisavings'          // fixes the network name used by scripts/apictl.sh
    JAVA_HOME            = "${tool name: 'jdk21', type: 'jdk'}"
    PATH                 = "${env.JAVA_HOME}/bin:${env.PATH}"
  }

  stages {

    stage('Build MI (CAR)') {
      steps {
        sh './mvnw -B clean install -DskipTests'
        archiveArtifacts artifacts: 'target/*.car', fingerprint: true
      }
    }

    stage('Package APIM') {
      steps {
        sh 'bash scripts/package-apim.sh'
        script {
          // Validate every API artifact up front: nothing is deployed unless all three are packaged
          APIS.each { api ->
            if (!fileExists("target/apim/${api}_v1.zip")) { error("Missing APIM bundle for ${api}") }
          }
        }
        archiveArtifacts artifacts: 'target/apim/**', fingerprint: true
      }
    }

    stage('Dev: start environment') {
      steps {
        sh '''
          docker compose --profile apim up -d mysql apim
          for i in $(seq 1 60); do
            [ "$(docker inspect -f '{{.State.Health.Status}}' jamii-apim)" = healthy ] && exit 0; sleep 10
          done
          echo "APIM did not become healthy"; exit 1
        '''
      }
    }

    stage('Dev: deploy MI') {
      steps { sh 'bash scripts/deploy-mi.sh' }   // one CAR carries all three APIs: atomic MI deploy
    }

    stage('Dev: test MI') {
      steps {
        sh 'bash tests/smoke.sh'
        script { if (params.FAULT_TESTS) { sh 'FAULT_TESTS=1 bash tests/smoke.sh' } }
      }
    }

    stage('Dev: deploy APIM') {
      // Only reached if all MI tests passed. deploy-apim.sh stops at the first failing import.
      steps { sh 'bash scripts/deploy-apim.sh dev target/apim' }
    }

    stage('Dev: test through gateway') {
      steps { sh 'GATEWAY=1 bash tests/smoke.sh' }
    }

    stage('Prod: approval') {
      when { expression { params.PROMOTE_TO_PROD } }
      steps {
        timeout(time: 30, unit: 'MINUTES') {
          input message: "Deploy build #${env.BUILD_NUMBER} (${APIS.join(', ')}) to PROD?", ok: 'Deploy'
        }
      }
    }

    stage('Prod: deploy') {
      when { expression { params.PROMOTE_TO_PROD } }
      environment {
        // Conceptual: these credentials/targets do not exist in this assignment.
        APIM_URL   = 'https://apim.prod.jamii.internal:9443'
        APIM_CREDS = credentials('jamii-apim-prod')       // username/password credential
      }
      steps {
        sh '''
          # MI: the same CAR is promoted (never rebuilt). Target runtime is not wired in this repo.
          [ -n "${PROD_MI_DEPLOY_CMD:-}" ] || { echo "PROD MI target not configured; refusing to half-deploy"; exit 1; }
          eval "$PROD_MI_DEPLOY_CMD target/JamiiSavings_1.0.0.car"
          APIM_USER="$APIM_CREDS_USR" APIM_PASS="$APIM_CREDS_PSW" bash scripts/deploy-apim.sh prod target/apim
        '''
      }
    }
  }

  post {
    failure {
      script {
        // APIM imports are per-artifact, so a failure part-way can leave dev mixed.
        // Re-apply the last successful build's bundles to bring APIM dev back to a consistent set.
        try {
          copyArtifacts projectName: env.JOB_NAME, selector: lastSuccessful(), filter: 'target/apim/**', target: 'rollback'
          sh 'bash scripts/deploy-apim.sh dev rollback/target/apim || echo "Rollback failed: manual action needed"'
        } catch (e) {
          echo "No previous successful build to roll back to (${e.message})"
        }
      }
    }
    always {
      sh '''
        mkdir -p logs
        for c in jamii-mi jamii-apim jamii-mysql; do docker logs "$c" > "logs/$c.log" 2>&1 || true; done
      '''
      archiveArtifacts artifacts: 'logs/*.log', allowEmptyArchive: true
      script { if (!params.KEEP_DEV_ENV) { sh 'docker compose --profile apim down -v || true' } }
    }
  }
}
