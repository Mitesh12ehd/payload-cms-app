pipeline {
  agent any

  options {
    disableConcurrentBuilds()          // never run two deploys at once
    timeout(time: 45, unit: 'MINUTES')
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  parameters {
    string(name: 'ROLLBACK_TAG', defaultValue: '',
           description: 'Leave empty for a normal build. Set to an existing ECR tag (e.g. 57-a1b2c3d) to redeploy that image without building.')
  }

  environment {
    AWS_REGION       = 'ap-south-1'
    AWS_ACCOUNT      = '416536281952'
    ECR_REPO         = 'payload-cms-app'
    ECR_URI          = "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

    // ALB target group that contains the two EC2 instances
    TARGET_GROUP_ARN = 'arn:aws:elasticloadbalancing:ap-south-1:416536281952:targetgroup/payload-app-tg/8cbd30baf27cb246'
    APP_HOSTS        = '10.0.1.99 10.0.2.94'
    SSH_USER         = 'ec2-user'

    // Public URL used for the final smoke test through the ALB
    APP_URL          = 'http://payload-alb-308154203.ap-south-1.elb.amazonaws.com/'

    DOCKER_BUILDKIT  = '1'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          def sha = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
          env.IMAGE_TAG = params.ROLLBACK_TAG ?: "${BUILD_NUMBER}-${sha}"
          currentBuild.displayName = "#${BUILD_NUMBER} ${env.IMAGE_TAG}"
        }
      }
    }

    stage('Build images') {
      when { expression { !params.ROLLBACK_TAG } }
      steps {
        // Secrets are passed as BuildKit secrets: they are NOT stored in any image layer or `docker history`.
        withCredentials([
          string(credentialsId: 'database-url',  variable: 'DATABASE_URL'),
          string(credentialsId: 'payload-secret', variable: 'PAYLOAD_SECRET')
        ]) {
          sh '''
            docker build --target runner \
              --secret id=database_url,env=DATABASE_URL \
              --secret id=payload_secret,env=PAYLOAD_SECRET \
              -t ${ECR_URI}:${IMAGE_TAG} .

            # one-off image that contains the Payload CLI, used only to run DB migrations
            docker build --target migrator \
              --secret id=database_url,env=DATABASE_URL \
              --secret id=payload_secret,env=PAYLOAD_SECRET \
              -t ${ECR_URI}:${IMAGE_TAG}-migrate .
          '''
        }
      }
    }

    stage('Push to ECR') {
      when { expression { !params.ROLLBACK_TAG } }
      steps {
        sh '''
          aws ecr get-login-password --region ${AWS_REGION} \
            | docker login --username AWS --password-stdin ${ECR_URI}
          docker push ${ECR_URI}:${IMAGE_TAG}
          docker push ${ECR_URI}:${IMAGE_TAG}-migrate
        '''
      }
    }

    stage('DB migrations') {
      when {
        allOf {
          expression { !params.ROLLBACK_TAG }
          expression { env.GIT_BRANCH ==~ /(origin\/)?main/ }
        }
      }
      steps {
        // Runs ONCE (not per instance). Migrations must be backward compatible with the
        // currently running version because old and new code run side by side during the rollout.
        withCredentials([
          string(credentialsId: 'database-url',  variable: 'DATABASE_URL'),
          string(credentialsId: 'payload-secret', variable: 'PAYLOAD_SECRET')
        ]) {
          sshagent(credentials: ['ec2-ssh-key']) {
            sh '''#!/usr/bin/env bash
              set -euo pipefail
              SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
              FIRST_HOST=$(echo ${APP_HOSTS} | awk '{print $1}')
              scp $SSH_OPTS deploy/host-deploy.sh ${SSH_USER}@${FIRST_HOST}:/tmp/host-deploy.sh
              printf 'DATABASE_URL=%s\nPAYLOAD_SECRET=%s\n' "$DATABASE_URL" "$PAYLOAD_SECRET" \
                | ssh $SSH_OPTS ${SSH_USER}@${FIRST_HOST} \
                  "ECR_URI='${ECR_URI}' IMAGE_TAG='${IMAGE_TAG}' AWS_REGION='${AWS_REGION}' bash /tmp/host-deploy.sh migrate"
            '''
          }
        }
      }
    }

    stage('Rolling deploy') {
      when { expression { env.GIT_BRANCH ==~ /(origin\/)?main/ } }
      steps {
        withCredentials([
          string(credentialsId: 'database-url',  variable: 'DATABASE_URL'),
          string(credentialsId: 'payload-secret', variable: 'PAYLOAD_SECRET')
        ]) {
          sshagent(credentials: ['ec2-ssh-key']) {
            sh 'bash deploy/rolling-deploy.sh'
          }
        }
      }
    }

    stage('Smoke test via ALB') {
      when { expression { env.GIT_BRANCH ==~ /(origin\/)?main/ } }
      steps {
        sh 'curl -fsS --retry 5 --retry-delay 5 --max-time 10 ${APP_URL}/api/health'
      }
    }
  }

  post {
    always  { sh 'docker image prune -f || true' }
    failure { echo "Deploy failed. Previous version is still serving (or was restored) - check logs above. To redeploy a known-good image, run with ROLLBACK_TAG." }
  }
}