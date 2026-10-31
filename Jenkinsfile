pipeline {
  agent any

  environment {
    AWS_REGION   = 'ap-south-1'
    AWS_ACCOUNT  = '416536281952'
    ECR_REPO     = 'payload-cms-app'
    ECR_URI      = "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
    IMAGE_TAG    = "${BUILD_NUMBER}"
    APP1_HOST    = '10.0.1.99'
    APP2_HOST    = '10.0.2.94'
    SSH_USER     = 'ec2-user'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Build image') {
      steps {
        withCredentials([
          string(credentialsId: 'database-url', variable: 'DATABASE_URL'),
          string(credentialsId: 'payload-secret', variable: 'PAYLOAD_SECRET')
        ]) {
          sh '''
            docker build \
              --build-arg DATABASE_URL="$DATABASE_URL" \
              --build-arg PAYLOAD_SECRET="$PAYLOAD_SECRET" \
              -t ${ECR_URI}:${IMAGE_TAG} \
              -t ${ECR_URI}:latest \
              .
          '''
        }
      }
    }

    stage('Push to ECR') {
      steps {
        sh '''
          aws ecr get-login-password --region ${AWS_REGION} \
            | docker login --username AWS --password-stdin ${ECR_URI}
          docker push ${ECR_URI}:${IMAGE_TAG}
          docker push ${ECR_URI}:latest
        '''
      }
    }

    stage('Deploy to both EC2s') {
      steps {
        withCredentials([
          string(credentialsId: 'database-url', variable: 'DATABASE_URL'),
          string(credentialsId: 'payload-secret', variable: 'PAYLOAD_SECRET')
        ]) {
          sshagent(credentials: ['ec2-ssh-key']) {
            sh '''
              set -e
              for HOST in ${APP1_HOST} ${APP2_HOST}; do
                echo "Deploying to $HOST"

                printf 'DATABASE_URL=%s\nPAYLOAD_SECRET=%s\nNODE_ENV=production\n' \
                  "$DATABASE_URL" "$PAYLOAD_SECRET" \
                | ssh -o StrictHostKeyChecking=no ${SSH_USER}@$HOST "
                    set -e
                    aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_URI}
                    docker pull ${ECR_URI}:${IMAGE_TAG}
                    docker rm -f payload-cms || true
                    docker run -d --name payload-cms --restart unless-stopped \
                      -p 3000:3000 \
                      --env-file /dev/stdin \
                      ${ECR_URI}:${IMAGE_TAG}
                    docker image prune -f
                  "
              done
            '''
          }
        }
      }
    }
  }
}